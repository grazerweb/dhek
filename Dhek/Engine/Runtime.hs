{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
--------------------------------------------------------------------------------
-- |
-- Module : Dhek.Engine.Runtime
--
-- Runtime Intruction interpreter
--------------------------------------------------------------------------------
module Dhek.Engine.Runtime where

--------------------------------------------------------------------------------
import           Prelude hiding (foldr)
import           Control.Applicative
import           Data.Array (Array, array, (!))
import           Data.Char (isSpace)
import           Data.Foldable (foldr, for_, traverse_)
import qualified Data.IntMap as I
import           Data.IORef
import           Data.List (dropWhileEnd)

--------------------------------------------------------------------------------
import           Control.Lens hiding (zoom)
import           Control.Monad.State
import           Control.Monad.RWS.Strict
import           Data.Text (Text)
import qualified Graphics.UI.Gtk                  as Gtk
import qualified Graphics.UI.Gtk.Poppler.Document as Poppler
import qualified Graphics.UI.Gtk.Poppler.Page     as Poppler

--------------------------------------------------------------------------------
import Dhek.Cartesian
import Dhek.Engine.Instr
import Dhek.Engine.Misc.LastHistory
import Dhek.Engine.Type
import Dhek.GUI
import Dhek.GUI.Action
import Dhek.Mode.Duplicate
import Dhek.Mode.Normal
import Dhek.Mode.Selection
import Dhek.Types

--------------------------------------------------------------------------------
data ModeInfo
    = ModeInfo
      { _modeInfoMgr  :: !ModeManager
      , _modeInfoPrev :: !(Maybe DhekMode)
      , _modeInfoCur  :: !DhekMode
      }

--------------------------------------------------------------------------------
data RuntimeEnv
    = RuntimeEnv
      { _internal :: IORef (Maybe Viewer)
      , _state    :: IORef EngineState
      , _env      :: IORef EngineEnv
      , _gui      :: GUI
      , _modes    :: Modes
      , _modeInfo :: IORef ModeInfo
      }

--------------------------------------------------------------------------------
data Modes
    = Modes
      { modeDraw            :: IO ModeManager
      , modeDuplication     :: IO ModeManager
      , modeSelection       :: IO ModeManager
      }

--------------------------------------------------------------------------------
newtype DefaultRuntime a
    = DR (RWST RuntimeEnv () EngineState IO a)
    deriving ( Functor
             , Applicative
             , Monad
             , MonadIO
             , MonadState EngineState
             , MonadReader RuntimeEnv
             )

--------------------------------------------------------------------------------
instance Runtime DefaultRuntime where
    rGetSelected
        = do mSid <- use $ engineDrawState.drawSelected.to lhPeek
             mSel <- traverse engineStateGetRect mSid
             return $ join mSel

    rGetAllSelected
        = do gui <- asks _gui
             liftIO $ gtkGetTreeAllSelection gui

    rSetSelected r
        = do g <- asks _gui
             maybe (liftIO $ gtkUnselect g) (_selectRect g) r

    rGetRectangles
        = fmap getRects get

    rGetCurPage
        = use engineCurPage

    rGetPageCount
        = do ref  <- asks _internal
             vopt <- liftIO $ readIORef ref
             return $ maybe (-1) (\v -> v ^. viewerPageCount) vopt

    rIncrPage
        = do engineDrawState.drawSelected .= lhNew
             ncur <- engineCurPage <+= 1
             g    <- asks _gui
             s    <- get
             nb   <- rGetPageCount
             liftIO $ gtkIncrPage ncur nb (getRects s) g

    rIncrZoom
        = do g    <- asks _gui
             ncur <- engineCurZoom <+= 1
             liftIO $ gtkIncrZoom ncur 10 g

    rDecrPage
        = do engineDrawState.drawSelected .= lhNew
             ncur <- engineCurPage <-= 1
             g    <- asks _gui
             s    <- get
             liftIO $ gtkDecrPage ncur 1 (getRects s) g

    rDecrZoom
        = do g    <- asks _gui
             ncur <- engineCurZoom <-= 1
             liftIO $ gtkDecrZoom ncur 1 g

    rRemoveRect r
        = do g   <- asks _gui
             pid <- use engineCurPage
             let rid = r ^. rectId
             engineBoards.boardsMap.at pid.traverse.boardRects.at rid .= Nothing
             liftIO $ gtkRemoveRect r g

    rUnselectRect
        = do g <- asks _gui
             engineDrawState.drawSelected %= lhPop
             mSid <- use $ engineDrawState.drawSelected.to lhPeek
             mSel <- traverse engineStateGetRect mSid
             let mSelected = join mSel
             liftIO $ maybe (gtkUnselect g) (\r -> gtkSelectRect r g) mSelected

    rDraw
        = engineDraw .= True

    rSetTitle t
        = do g <- asks _gui
             liftIO $ Gtk.windowSetTitle (guiWindow g) t

    rGetFilename
        = do eref <- asks _env
             env  <- liftIO $ readIORef eref
             return $ _engineFilename env

    rShowError e
        = do g <- asks _gui
             liftIO $ gtkShowError e g

    rGetTreeSelection
        = do g <- asks _gui
             liftIO $ gtkGetTreeSelection g

    rGuideNew t
        = engineDrawState.drawNewGuide ?= Guide 0 t

    rGuideUpdate
        = do gui <- asks _gui
             x <- liftIO $ Gtk.get (guiHRuler gui) Gtk.rulerPosition
             y <- liftIO $ Gtk.get (guiVRuler gui) Gtk.rulerPosition

             let upd g =
                     let v = case g ^. guideType of
                             GuideVertical   -> x
                             GuideHorizontal -> y in
                     g & guideValue .~ v

             engineDrawState.drawNewGuide %= fmap upd

    rGuideAdd
        = do pid  <- use engineCurPage
             gOpt <- use $ engineDrawState.drawNewGuide
             gs   <- use $ engineBoards.boardsMap.at pid.traverse.boardGuides

             let gs1 = foldr (:) gs gOpt

             engineDrawState.drawNewGuide .= Nothing
             engineBoards.boardsMap.at pid.traverse.boardGuides .= gs1

    rGuideGetCur
        = use $ engineDrawState.drawNewGuide

    rGetGuides
        = do pid <- use engineCurPage
             use $ engineBoards.boardsMap.at pid.traverse.boardGuides

    rSelectJsonFile
        = do g <- asks _gui
             liftIO $ gtkSelectJsonFile  g

    rGetAllRects
        = engineGetAllRects

    rSetAllRects xs
        = do g <- asks _gui
             engineBoards                .= b
             engineDrawState.drawFreshId .= b ^. boardsState
             s <- get

             liftIO $ gtkSetRects (getRects s) g
      where
        onEach page r
            = do nid <- boardsState <+= 1
                 let r1 = r & rectId .~ nid
                 boardsMap.at page.traverse.boardRects.at nid ?= r1

        go (page, rs) = traverse_ (onEach page) rs
        action        = traverse_ go xs
        nb            = length xs
        b             = execState action (boardsNew nb)

    rOpenJsonFile
        = do g <- asks _gui
             liftIO $ gtkOpenJsonFile g

    rActive opt b
        = case opt of
            Overlap ->
                do g <- asks _gui
                   engineOverlap .= b
                   liftIO $ gtkSetOverlapActive g b
            Magnetic ->
                do g <- asks _gui
                   engineMagnetic .= b
                   liftIO $ gtkSetMagneticActive g b

    rIsActive opt
        = case opt of
            Overlap  -> use engineOverlap
            Magnetic -> use engineMagnetic

    rAddEvent e
        = engineEventStack %= (e:)

    rClearEvents
        = engineEventStack .= []

    rShowWarning e
        = do g <- asks _gui
             liftIO $ gtkShowWarning g e

--------------------------------------------------------------------------------
engineRunMode :: RuntimeEnv -> M a -> IO ()
engineRunMode i instr
    = do s  <- readIORef $ _state i
         mi <- readIORef $ _modeInfo i
         s2 <- runMode (mgrMode $ _modeInfoMgr mi) s instr
         writeIORef (_state i) s2

--------------------------------------------------------------------------------
engineModePointerContext :: [Gtk.Modifier]
                         -> (DrawEnv -> M a)
                         -> RuntimeEnv
                         -> Pos
                         -> IO ()
engineModePointerContext xs k i (x,y) = do
    s   <- readIORef $ _state i
    opt <- readIORef $ _internal i

    for_ opt $ \v -> do
        let gui   = _gui i
            ratio = _engineRatio s v
            opts  = DrawEnv
                    { drawPointer  = point2D (x/ratio) (y/ratio)
                    , drawRects    = getRects s
                    , drawRatio    = ratio
                    , drawModifier = xs
                    }

        engineRunMode i (k opts)
        liftIO $ Gtk.widgetQueueDraw $ guiDrawingArea gui

--------------------------------------------------------------------------------
engineModeKbContext :: [Gtk.Modifier]
                    -> Text
                    -> RuntimeEnv
                    -> (KbEnv -> M a)
                    -> IO ()
engineModeKbContext modf kname i k
    = do let kbenv = KbEnv
                    { kbModifier = modf
                    , kbKeyName  = kname
                    }

         engineRunMode i (k kbenv)

--------------------------------------------------------------------------------
engineModeMove :: [Gtk.Modifier] -> RuntimeEnv -> Pos -> IO ()
engineModeMove modf env pos = engineModePointerContext modf move env pos

--------------------------------------------------------------------------------
engineModePress :: [Gtk.Modifier] -> RuntimeEnv -> Pos -> IO ()
engineModePress modf env pos = engineModePointerContext modf press env pos

--------------------------------------------------------------------------------
engineModeRelease :: [Gtk.Modifier] -> RuntimeEnv -> Pos -> IO ()
engineModeRelease modf env pos = engineModePointerContext modf release env pos

--------------------------------------------------------------------------------
engineModeKeyPress :: [Gtk.Modifier] -> Text -> RuntimeEnv -> IO ()
engineModeKeyPress modf name env = engineModeKbContext modf name env keyPress

--------------------------------------------------------------------------------
engineModeKeyRelease :: [Gtk.Modifier] -> Text -> RuntimeEnv -> IO ()
engineModeKeyRelease modf name env = engineModeKbContext modf name env keyRelease

--------------------------------------------------------------------------------
engineModeEnter :: RuntimeEnv -> IO ()
engineModeEnter i = engineRunMode i enter

--------------------------------------------------------------------------------
engineModeLeave :: RuntimeEnv -> IO ()
engineModeLeave i = engineRunMode i leave

--------------------------------------------------------------------------------
engineModeDraw :: RuntimeEnv -> IO ()
engineModeDraw i = do
    s   <- readIORef $ _state i
    opt <- readIORef $ _internal i
    mi  <- readIORef $ _modeInfo i
    for_ opt $ \v -> do
        let pages = v ^. viewerPages
            page  = pages ! (s ^. engineCurPage)
            ratio = _engineRatio s v
        s2 <- runMode (mgrMode $ _modeInfoMgr mi) s (drawing page ratio)
        writeIORef (_state i) s2

--------------------------------------------------------------------------------
_selectRect :: (MonadState EngineState m, MonadIO m) => GUI -> Rect -> m ()
_selectRect gui r = do
     let rid = r ^. rectId

     pid <- use engineCurPage

     engineDrawState.drawSelected %= lhPush (r ^. rectId)
     engineBoards.boardsMap.at pid.traverse.boardRects.at rid ?= r

     liftIO $ gtkSelectRect r gui

--------------------------------------------------------------------------------
engineCurrentState :: RuntimeEnv -> IO EngineState
engineCurrentState  = readIORef . _state

--------------------------------------------------------------------------------
engineCurrentPage :: RuntimeEnv -> IO (Maybe PageItem)
engineCurrentPage  i = do
    opt <- readIORef $ _internal i
    s   <- readIORef $ _state i
    return $ fmap (_engineCurrentPage s) opt

--------------------------------------------------------------------------------
_engineCurrentPage :: EngineState -> Viewer -> PageItem
_engineCurrentPage s v =
     let pages = v ^. viewerPages
         pid   = s ^. engineCurPage in
     pages ! pid

--------------------------------------------------------------------------------
engineDrawingArea :: RuntimeEnv -> Gtk.DrawingArea
engineDrawingArea = guiDrawingArea . _gui

--------------------------------------------------------------------------------
-- | Changes engine internal mode
--
--   Internal:
--   --------
--
--   Gets both @EngineState@ and @EngineEnv@ references. Then we call
--   @ModeManager@ cleanup handler of the previous mode. We get a new
--   @EngineState@ out of cleanup handler. That new state is used to store
--   the new @ModeManager@
engineSetMode :: DhekMode -> RuntimeEnv -> IO ()
engineSetMode m i = do
    s  <- readIORef $ _state i
    mi <- readIORef $ _modeInfo i
    let prevMgr = _modeInfoMgr mi
        cleanup  = mgrCleanup prevMgr
    s2  <- execStateT cleanup s
    mgr <- selector modes
    let prevMode = _modeInfoCur mi
        mi'      = mi { _modeInfoPrev = Just prevMode
                      , _modeInfoCur  = m
                      , _modeInfoMgr  = mgr
                      }
    writeIORef (_state i) s2
    writeIORef (_modeInfo i) mi'

    Gtk.widgetQueueDraw area

  where
    modes    = _modes i
    area     = guiDrawingArea $ _gui i
    selector = case m of
        DhekNormal          -> modeDraw
        DhekDuplication     -> modeDuplication
        DhekSelection       -> modeSelection

--------------------------------------------------------------------------------
-- | Returns the current page ratio. Returns Nothing if no PDF has been loaded
--   yet.
engineRatio :: RuntimeEnv -> IO (Maybe Double)
engineRatio i = do
    opt <- readIORef $ _internal i
    s   <- readIORef $ _state i
    return $ fmap (_engineRatio s) opt

--------------------------------------------------------------------------------
_engineRatio :: EngineState -> Viewer -> Double
_engineRatio s v =
    let pages = v ^. viewerPages
        zoom  = zoomValues ! (s ^. engineCurZoom)
        pid   = s ^. engineCurPage
        width = pageWidth (pages ! pid)
        base  = fromIntegral (s ^. engineBaseWidth) in
    (base * zoom) / width

--------------------------------------------------------------------------------
engineGetAllRects :: MonadState EngineState m => m [(Int, [Rect])]
engineGetAllRects
    = let tup (i, b) = (i, b ^. boardRects.to I.elems)
          list       = fmap tup . I.toList in
      use $ engineBoards.boardsMap.to list

--------------------------------------------------------------------------------
makeRuntimeEnv :: GUI -> IO RuntimeEnv
makeRuntimeEnv gui = do
    let env = EngineEnv { _engineFilename = "" }
    eRef <- newIORef env
    sRef <- newIORef stateNew
    vRef <- newIORef Nothing

    -- Instanciates ModeManagers
    let mgrNormal        = normalModeManager gui
        mgrDuplication   = duplicateModeManager gui
        mgrSelection     = selectionModeManager (_withContext sRef) gui
        modes = Modes
                { modeDraw            = mgrNormal
                , modeDuplication     = mgrDuplication
                , modeSelection       = mgrSelection
                }

    curMgr <- mgrNormal
    let mi = ModeInfo
             { _modeInfoMgr  = curMgr
             , _modeInfoCur  = DhekNormal
             , _modeInfoPrev = Nothing
             }
    cRef   <- newIORef mi
    return RuntimeEnv{ _internal   = vRef
                     , _state      = sRef
                     , _env        = eRef
                     , _gui        = gui
                     , _modes      = modes
                     , _modeInfo   = cRef
                     }

--------------------------------------------------------------------------------
stateNew :: EngineState
stateNew
    = EngineState
      { _engineCurPage      = 1
      , _engineCurZoom      = 3
      , _engineRectId       = 0
      , _engineOverlap      = False
      , _engineMagnetic     = True
      , _engineDraw         = False
      , _enginePropLabel    = ""
      , _enginePropType     = Nothing
      , _enginePrevPos      = (negate 1, negate 1)
      , _engineDrawState    = drawStateNew
      , _engineBoards       = boardsNew 1
      , _engineBaseWidth    = 777
      , _engineThick        = 1
      , _engineEventStack   = []
      }

--------------------------------------------------------------------------------
runProgram :: RuntimeEnv -> Instr a -> IO a
runProgram i (Instr (DR action))
    = do s          <- readIORef (_state i)
         (a, s', _) <- runRWST action i s
         let redraw = s' ^. engineDraw
             s''    = s' & engineDraw .~ False
         writeIORef (_state i) s''
         when redraw (Gtk.widgetQueueDraw $ guiDrawingArea $ _gui i)
         return a

--------------------------------------------------------------------------------
engineHasEvents :: RuntimeEnv -> IO Bool
engineHasEvents i
    = _engineWithContext i $
          do rs <- engineGetAllRects
             let rs' = rs >>= snd
             evs <- use engineEventStack
             return ((not $ null evs) && (not $ null rs'))

--------------------------------------------------------------------------------
_engineWithContext :: RuntimeEnv -> (forall m. EngineCtx m => m a) -> IO a
_engineWithContext i = _withContext $ _state i

--------------------------------------------------------------------------------
_withContext :: IORef EngineState -> (forall m. EngineCtx m => m a) -> IO a
_withContext ref action = do
    s      <- readIORef ref
    (a,s') <- runStateT action s
    writeIORef ref s'
    return a

--------------------------------------------------------------------------------
lookupStoreIter :: (a -> Bool) -> Gtk.ListStore a -> IO (Maybe Gtk.TreeIter)
lookupStoreIter predicate store = Gtk.treeModelGetIterFirst store >>= go
  where
    go (Just it) = do
        a <- Gtk.listStoreGetValue store (Gtk.listStoreIterToIndex it)
        if predicate a
            then return (Just it)
            else Gtk.treeModelIterNext store it >>= go
    go _ = return Nothing

--------------------------------------------------------------------------------
lookupEntryText :: Gtk.Entry -> IO (Maybe String)
lookupEntryText entry = do
    txt <- Gtk.entryGetText entry
    let txt1 = trimString txt
        r    = if null txt1 then Nothing else Just txt1
    return r

--------------------------------------------------------------------------------
_getRatio :: EngineState -> Viewer -> Double
_getRatio s v = (base * zoom) / width
  where
    pIdx  = _engineCurPage s
    zIdx  = _engineCurZoom s
    pages = _viewerPages v
    base  = fromIntegral $ (s ^. engineBaseWidth)
    width = pageWidth (pages ! pIdx)
    zoom  = zoomValues ! zIdx

--------------------------------------------------------------------------------
_getPage :: EngineState -> Viewer -> PageItem
_getPage s v = pages ! pIdx
  where
    pIdx  = _engineCurPage s
    pages = _viewerPages v

--------------------------------------------------------------------------------
getRects :: EngineState -> [Rect]
getRects s =
    let pId   = s ^. engineCurPage
        rects =
            s ^. engineBoards.boardsMap.at pId.traverse.boardRects.to I.elems in
    rects

--------------------------------------------------------------------------------
zoomValues :: Array Int Double
zoomValues = array (0, 10) values
  where
    values = [(0,  0.125) -- 12.5%
             ,(1,  0.25)  -- 25%
             ,(2,  0.5)   -- 50%
             ,(3,  1.0)   -- 100%
             ,(4,  2.0)   -- 200%
             ,(5,  3.0)   -- 300%
             ,(6,  4.0)   -- 400%
             ,(7,  5.0)   -- 500%
             ,(8,  6.0)   -- 600%
             ,(9,  7.0)   -- 700%
             ,(10, 8.0)]  -- 800%

--------------------------------------------------------------------------------
loadPdfFileDoc :: FilePath -> IO Poppler.Document
loadPdfFileDoc path
    = do Just doc <- Poppler.documentNewFromFile path Nothing
         return doc

--------------------------------------------------------------------------------
loadPdfInlinedDoc :: String -> IO Poppler.Document
loadPdfInlinedDoc repr
    = do Just doc <- Poppler.documentNewFromData repr Nothing
         return doc

--------------------------------------------------------------------------------
loadViewer :: RuntimeEnv -> Viewer -> IO ()
loadViewer i v = do
    opt <- readIORef $ _internal i
    s   <- readIORef $ _state i
    ev  <- readIORef $ _env i
    case opt of
        Nothing -> do
            let env  = EngineEnv { _engineFilename = v ^. viewerName }
                name = _engineFilename env
                nb   = v ^. viewerPageCount
                s'   = s & engineBoards .~ boardsNew nb
            Gtk.widgetDestroy (guiSplashAlign gui)
            writeIORef (_internal i) (Just v)
            writeIORef (_env i) env
            writeIORef (_state i) s'
            ahbox <- Gtk.alignmentNew 0 0 1 1
            Gtk.containerAdd ahbox (guiWindowHBox gui)
            Gtk.boxPackStart (guiWindowVBox gui) ahbox Gtk.PackGrow 0
            Gtk.widgetSetSensitive (guiJsonOpenMenuItem gui) True
            Gtk.widgetSetSensitive (guiJsonSaveMenuItem gui) True
            Gtk.widgetSetSensitive (guiOverlapMenuItem gui) True
            Gtk.widgetSetSensitive (guiMagneticForceMenuItem gui) True
            Gtk.widgetSetSensitive (guiPrevButton gui) False
            Gtk.widgetSetSensitive (guiNextButton gui) (nb /= 1)
            Gtk.windowSetTitle (guiWindow gui)
                (name ++ " (page 1 / " ++ show nb ++ ")")
            Gtk.widgetShowAll ahbox
        Just _ -> do
            let env  = ev {  _engineFilename = v ^. viewerName }
                name = _engineFilename env
                nb   = v ^. viewerPageCount
                ds   = s ^. engineDrawState
                s'   = s { _engineOverlap    = s ^. engineOverlap
                         , _engineBoards     = boardsNew nb
                         , _engineCurPage    = 1
                         , _engineCurZoom    = 3
                         , _engineDrawState  = ds { _drawFreshId = 0 }
                         , _engineEventStack = []
                         }
            writeIORef (_internal i) (Just v)
            writeIORef (_env i) env
            writeIORef (_state i) s'
            guiClearPdfCache gui
            Gtk.listStoreClear $ guiRectStore gui
            Gtk.widgetSetSensitive (guiJsonOpenMenuItem gui) True
            Gtk.widgetSetSensitive (guiJsonSaveMenuItem gui) True
            Gtk.widgetSetSensitive (guiOverlapMenuItem gui) True
            Gtk.widgetSetSensitive (guiMagneticForceMenuItem gui) True
            Gtk.widgetSetSensitive (guiPrevButton gui) False
            Gtk.widgetSetSensitive (guiNextButton gui) (nb /= 1)
            Gtk.windowSetTitle (guiWindow gui)
                (name ++ " (page 1 / " ++ show nb ++ ")")
            engineSetMode DhekNormal i
    Gtk.widgetGrabFocus (guiDrawingArea gui)
  where
    gui = _gui i

--------------------------------------------------------------------------------
makeViewer :: String -> Poppler.Document -> IO Viewer
makeViewer name doc = do
    nb    <- Poppler.documentGetNPages doc
    pages <- _loadPages doc

    let v = Viewer{ _viewerDocument  = doc
                  , _viewerPages     = pages
                  , _viewerPageCount = nb
                  , _viewerName      = name
                  }
    return v

--------------------------------------------------------------------------------
_loadPages :: Poppler.Document -> IO (Array Int PageItem)
_loadPages doc = do
    nb <- Poppler.documentGetNPages doc
    fmap (array (1,nb)) (traverse go [1..nb])
  where
    go i = do
        page  <- Poppler.documentGetPage doc (i-1)
        (w,h) <- Poppler.pageGetSize page
        return (i, PageItem page w h)

--------------------------------------------------------------------------------
trimString :: String -> String
trimString = dropWhileEnd isSpace . dropWhile isSpace
