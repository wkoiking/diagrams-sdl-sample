{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

import qualified SDL as SDL
import Foreign.Ptr ( castPtr )
import qualified Graphics.Rendering.Cairo as Cairo

-- diagrams
import Diagrams.Prelude hiding (view)
import Diagrams.TwoD.Text (text)
import Diagrams.TwoD.Image (imageEmb)

-- diagrams-cairo
import Diagrams.Backend.Cairo

-- diagrams-rasterific
-- import Diagrams.Backend.Rasterific (renderImage)

-- JuicyPixels
-- import Codec.Picture.Types (DynamicImage(..))

import Data.Time
-- import Data.Text (Text)
-- import TextShow
-- base
import Data.Int (Int32)
import Data.Word (Word8)
import Data.IORef (newIORef, writeIORef, readIORef, modifyIORef)
import Foreign.Ptr (nullPtr)
import Control.Monad (forM, forM_, replicateM)
import Data.Maybe (listToMaybe)

-- safe
-- import Safe (headMay)

-- palette
import Data.Colour.Palette.ColorSet

-- async
import Control.Concurrent.Async (forConcurrently_)

type NormalDiagram = Diagram V2

type GenericDiagram a = QDiagram V2 Double a

type SelectableDiagram = GenericDiagram [String]

-- rasterize :: SizeSpec V2 Int -> Diagram V2 -> Diagram V2
-- rasterize sz d = sizedAs d $ imageEmb $ ImageRGBA8 $ renderImage sz d

value :: Monoid m => m -> QDiagram v n Any -> QDiagram v n m
value m = fmap fromAny
  where fromAny (Any True)  = m
        fromAny (Any False) = mempty

resetValue :: (Eq m, Monoid m) => QDiagram v n m -> QDiagram v n Any
resetValue = fmap toAny
  where toAny m | m == mempty = Any False
                | otherwise   = Any True

clearValue :: QDiagram v n m -> QDiagram v n Any
clearValue = fmap (const (Any False))

--

data Model = Model
    { clockCount :: Int
    , triangleClickCount :: Int
    , squareClickCount :: Int
    }

initialModel :: Model
initialModel = Model 0 0 0

view :: Model -> [SelectableDiagram]
view Model{..} = map toSDLCoord $ [layer0, layer1, layer2, layer3] -- [mconcat [layer0, layer1, layer2, layer3]]
 where layer3 = mconcat
           [ scale 50 $ center $ vsep 1
               [ value [] $ text ("Clock count: " <> show clockCount) <> phantom (rect 10 1 :: NormalDiagram)
               , value [] $ text ("Triangle click count: " <> show triangleClickCount) <> phantom (rect 10 1 :: NormalDiagram)
               , value [] $ text ("Square click count: " <> show squareClickCount) <> phantom (rect 10 1 :: NormalDiagram)
               , hsep 1
                   [ triangle 1 # fc red # value ["triangle"]
                   , rect 1 1 # fc blue # value ["square"]
                   ]
               ]
           ]
       layer2 = sized (mkHeight screenHeight) $ center $ vcat $ replicate triangleClickCount $ hcat $ replicate triangleClickCount $ sampleTri # fc (d3Colors2 Dark triangleClickCount) # value []
       layer1 = sized (mkHeight screenHeight) $ center $ vcat $ replicate triangleClickCount $ hcat $ replicate triangleClickCount $ sampleSquare # fc (d3Colors2 Dark squareClickCount) # value []
       layer0 = sized (mkHeight screenHeight) $ center $ vcat $ replicate triangleClickCount $ hcat $ replicate triangleClickCount $ sampleCircle # fc (d3Colors2 Dark clockCount) # value []

       sampleTri :: NormalDiagram
       sampleTri = triangle 1
       sampleCircle :: NormalDiagram
       sampleCircle = circle 1
       sampleSquare :: NormalDiagram
       sampleSquare = rotate (45 @@ deg) $ square 1

updateWithClick :: String -> Model -> Model
updateWithClick "triangle" Model{..} = Model clockCount (triangleClickCount + 1) squareClickCount
updateWithClick "square" Model{..}   = Model clockCount triangleClickCount (squareClickCount + 1)
updateWithClick _ model              = model

updateWithTimer :: Model -> Model
updateWithTimer Model{..} = Model (clockCount + 1) triangleClickCount squareClickCount

-- sampleRasterImage :: NormalDiagram
-- sampleRasterImage = rasterize (mkWidth 100) $ text "a" # fc green <> phantom (rect 1 1 :: NormalDiagram)

fullHDRect :: NormalDiagram
fullHDRect = rect screenWidth screenHeight # fc white

screenWidth :: Num a => a
screenWidth = 800
screenHeight :: Num a => a
screenHeight = 600

main :: IO ()
main = do
    -- 編集の初期化
    vModel <- newIORef initialModel
    vRender <- newIORef $ view initialModel
    -- SDL初期化
    SDL.initialize [ SDL.InitVideo ]
    window <- SDL.createWindow
        "SDL / Cairo Example"
        SDL.defaultWindow {SDL.windowInitialSize = SDL.V2 screenWidth screenHeight}
    SDL.showWindow window
    
    screenSdlSurface <- SDL.getWindowSurface window
--     scrrenBuffer <- fmap castPtr $ SDL.surfacePixels screenSdlSurface
--     screenCairoSurface <- forM buffers $ \ buffer -> Cairo.createImageSurfaceForData buffer Cairo.FormatRGB24 screenWidth screenHeight (screenWidth * 4)
--     screenCairoSurface 

    sdlSurfaces <- replicateM 4 $ SDL.createRGBSurface (SDL.V2 screenWidth screenHeight) SDL.ARGB8888
    buffers <- mapM (fmap castPtr . SDL.surfacePixels) sdlSurfaces
    cairoSurfaces <- forM buffers $ \ buffer -> Cairo.createImageSurfaceForData buffer Cairo.FormatRGB24 screenWidth screenHeight (screenWidth * 4)

--     bufferSurface <- Cairo.createImageSurface Cairo.FormatRGB24 screenWidth screenHeight (screenWidth * 4)
--     Cairo.renderWith canvas demo3
--     Cairo.withImageSurfaceForData pixels Cairo.FormatRGB24 600 600 (600 * 4) $ \canvas -> do
--         Cairo.renderWith canvas demo3

    SDL.updateWindowSurface window

    -- Userイベントの登録
    mRegisteredEventType <- SDL.registerEvent decodeUserEvent encodeUserEvent
    let pushCustomEvent :: CustomEvent -> IO ()
        pushCustomEvent userEvent = forM_ mRegisteredEventType $ \ regEventType -> SDL.pushRegisteredEvent regEventType userEvent
        getCustomEvent :: SDL.Event -> IO (Maybe CustomEvent)
        getCustomEvent event = case mRegisteredEventType of
            Nothing -> return $ Nothing
            Just regEventType -> SDL.getRegisteredEvent regEventType event

    -- 定周期の処理
    _ <- SDL.addTimer 1000 $ const $ do
        modifyIORef vModel $ updateWithTimer
        pushCustomEvent CustomExposeEvent
        return $ SDL.Reschedule 1000

    pushCustomEvent CustomExposeEvent
    
    -- Eventハンドラ
    let loop :: IO ()
        loop = do
            event <- SDL.waitEvent
            mUserEvent <- getCustomEvent event
            forM_ mUserEvent $ \case
                CustomExposeEvent -> measuringTime $ do
                    model <- readIORef vModel
                    putStrLn $ show $ triangleClickCount model
                    let selectableDiagrams = view model
                    SDL.surfaceFillRect screenSdlSurface Nothing whiteRect
                    let targets = zip3 sdlSurfaces cairoSurfaces selectableDiagrams
                    forConcurrently_ targets $ \ (sdlSurface, cairoSurface, diagram) -> do
                        SDL.surfaceFillRect sdlSurface Nothing alphaRect
                        Cairo.renderWith cairoSurface $ toRender mempty $ clearValue diagram
                    forM_ sdlSurfaces $ \ sdlSurface -> do
                        SDL.surfaceBlit sdlSurface Nothing screenSdlSurface Nothing
                    SDL.updateWindowSurface window
                    writeIORef vRender selectableDiagrams
            case SDL.eventPayload event of
                SDL.MouseButtonEvent SDL.MouseButtonEventData{..} -> do
                    case mouseButtonEventMotion of
                        SDL.Pressed -> do
                            selectableDiagrams <- readIORef vRender
                            let mClickedObj = listToMaybe $ reverse $ sample (mconcat selectableDiagrams) $ toFloatingPoint $ mouseButtonEventPos
                            mapM_ (modifyIORef vModel . updateWithClick) mClickedObj
                            pushCustomEvent CustomExposeEvent
                            loop
                        _           -> loop
                SDL.QuitEvent       -> return ()
                _                   -> loop
--             let (_, _, r) = renderDiaT (mkOptions $ mkWidth 600 :: Options Cairo) $ a n
--             SDL.surfaceFillRect screenSurface Nothing whiteRect
--             measuringTime $ Cairo.renderWith canvas r
--             if SDL.QuitEvent `elem` map SDL.eventPayload events
--                 then return ()
--                 else loop $ n + 1
    loop
    putStrLn "Exitting"

data CustomEvent = CustomExposeEvent

decodeUserEvent :: SDL.RegisteredEventData -> SDL.Timestamp -> IO (Maybe CustomEvent)
decodeUserEvent SDL.RegisteredEventData{..} _ = case registeredEventCode of
    0 -> return $ Just CustomExposeEvent
    _ -> return Nothing

encodeUserEvent :: CustomEvent -> IO SDL.RegisteredEventData
encodeUserEvent CustomExposeEvent = return $ SDL.RegisteredEventData Nothing 0 nullPtr nullPtr

toSDLCoord :: SelectableDiagram -> SelectableDiagram
toSDLCoord = translate (V2 (screenWidth / 2) (screenHeight / 2)) . reflectY

toFloatingPoint :: Point V2 Int32 -> Point V2 Double
toFloatingPoint p = fmap fromIntegral p

whiteRect :: SDL.V4 Word8
whiteRect = SDL.V4 maxBound maxBound maxBound maxBound

alphaRect :: SDL.V4 Word8
alphaRect = SDL.V4 maxBound maxBound maxBound minBound

measuringTime :: IO () -> IO ()
measuringTime io = do
     t1 <- getCurrentTime
     io
     t2 <- getCurrentTime
     let diffTime = diffUTCTime t2 t1
     putStrLn $ show diffTime
