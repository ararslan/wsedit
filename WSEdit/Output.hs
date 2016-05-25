{-# LANGUAGE LambdaCase #-}

module WSEdit.Output
    ( charWidth
    , stringWidth
    , charRep
    , stringRep
    , visToTxtPos
    , txtToVisPos
    , lineNoWidth
    , toCursorDispPos
    , getViewportDimensions
    , makeFrame
    , draw
    ) where

import Control.Monad            (foldM)
import Control.Monad.IO.Class   (liftIO)
import Control.Monad.RWS.Strict (ask, get)
import Data.Default             (def)
import Data.Maybe               (fromJust, fromMaybe, isJust)
import Data.Tuple               (swap)
import Graphics.Vty             ( Background (ClearBackground)
                                , Cursor (Cursor, NoCursor)
                                , Image
                                , Picture ( Picture, picBackground, picCursor
                                          , picLayers
                                          )
                                , char, imageWidth, pad, reverseVideo, string
                                , translateX, update, vertCat, withStyle
                                , (<|>), (<->)
                                )
import Safe                     (lookupJustDef)

import WSEdit.Data              ( EdConfig (edDesign, vtyObj)
                                , EdDesign ( dBGChar, dBGFormat, dCharStyles
                                           , dColChar, dColNoFormat
                                           , dColNoInterval, dCurrLnMod
                                           , dFrameFormat, dLineNoFormat
                                           , dLineNoInterv, dSelFormat
                                           , dStatusFormat, dTabStr
                                           )
                                , EdState ( changed, drawBg, edLines, fname
                                          , markPos, readOnly, replaceTabs
                                          , scrollOffset, status, tabWidth
                                          )
                                , WSEdit
                                , getCursor, getFirstSelected, getDisplayBounds
                                , getLastSelected, getOffset
                                )
import WSEdit.Util              ( CharClass (Whitesp)
                                , charClass, padLeft, padRight, withSnd
                                )

import qualified WSEdit.Buffer as B





-- | Returns the display width of a given char in a given column.
charWidth :: Int -> Char -> WSEdit Int
charWidth n '\t' = (\w -> w - (n-1) `mod` w) . tabWidth <$> get
charWidth _ _    = return 1

-- | Returns the display width of a given string starting at a given column.
stringWidth :: Int -> String -> WSEdit Int
stringWidth n = foldM (\n' c -> (+ n') <$> charWidth (n'+1) c) $ n - 1





-- | Returns the visual representation of a character at a given buffer position
--   and in a given display column.
charRep :: (Int, Int) -> Int -> Char -> WSEdit Image
charRep pos n '\t' = do
    firstSel <- getFirstSelected
    lastSel  <- getLastSelected
    (r, _)   <- getCursor
    st       <- get
    d        <- edDesign <$> ask

    let
        selSty  = dSelFormat  d
        tW      = tabWidth    st
        tStr    = dTabStr     d
        tSty    = dCharStyles d
        currSty = dCurrLnMod  d

        tabSty  = lookupJustDef def Whitesp tSty

        s       = if isJust firstSel
                        && fromJust firstSel <= pos
                        && pos <= fromJust lastSel
                     then selSty
                     else tabSty

    return $ string (if r == fst pos
                            && s /= selSty
                            && not (readOnly st)
                        then currSty s
                        else s
                    )
           $ drop (length tStr - (tW - n `mod` tW)) tStr

charRep pos _ c = do
    firstSel <- getFirstSelected
    lastSel  <- getLastSelected
    (r, _)   <- getCursor
    st       <- get
    d        <- edDesign <$> ask

    let
        currSty = dCurrLnMod d
        selSty  = dSelFormat d
        charSty = lookupJustDef def (charClass c)
                $ dCharStyles d

        s       = if isJust firstSel
                        && fromJust firstSel <= pos
                        && pos <= fromJust lastSel
                     then selSty
                     else charSty

    return $ char (if r == fst pos
                            && s /= selSty
                            && not (readOnly st)
                        then currSty s
                        else s
                  ) c



-- | Returns the visual representation of a string at a given buffer position
--   and in a given display column.
stringRep :: Int -> (Int, Int) -> String -> WSEdit Image
stringRep n p s =
    let
        f :: (Image, Int, Int) -> Char -> WSEdit (Image, Int, Int)
        f (im, n', d) c = do
            i <- charRep (withSnd (+n') p) d c
            return (im <|> i, n' + 1, d + imageWidth i)
    in
        (\(r, _, _) -> r) <$> foldM f (string def "", 0, n) s



-- | Returns the textual position of the cursor in a line, given its visual one.
visToTxtPos :: String -> Int -> WSEdit Int
visToTxtPos = pos 1
    where
        pos :: Int -> String -> Int -> WSEdit Int
        pos _   []     _            = return 1
        pos col _      c | col == c = return 1
        pos col _      c | col >  c = return 0
        pos col (x:xs) c            = do
            w <- charWidth col x
            (+ 1) <$> pos (col + w) xs c


-- | Returns the visual position of the cursor in a line, given its textual one.
txtToVisPos :: String -> Int -> WSEdit Int
txtToVisPos txt n =  (+1)
                 <$> ( stringWidth 1
                     $ take (n - 1)
                       txt
                     )



-- | Returns the width of the line numbers column, based on the number of
--   lines the file has.
lineNoWidth :: WSEdit Int
lineNoWidth =  length
            .  show
            .  B.length
            .  edLines
           <$> get



-- | Return the cursor's position on the display, given its position in the
--   buffer.
toCursorDispPos :: (Int, Int) -> WSEdit (Int, Int)
toCursorDispPos (r, c) = do
    currLine <-  fromMaybe ""
              .  B.left
              .  edLines
             <$> get

    offset <- txtToVisPos currLine c

    n <- lineNoWidth
    (r', c') <- scrollOffset <$> get
    return (r - r' + 1, offset - c' + n + 3)


-- | Returns the number of rows, columns of text displayed.
getViewportDimensions :: WSEdit (Int, Int)
getViewportDimensions = do
    (nRows, nCols) <- getDisplayBounds
    lNoWidth <- lineNoWidth

    return (nRows - 4, nCols - lNoWidth - 4)





-- | Creates the top border of the interface.
makeHeader :: WSEdit Image
makeHeader = do
    d <- edDesign <$> ask
    lNoWidth <- lineNoWidth

    (_, scrollCols) <- getOffset
    (_, txtCols   ) <- getViewportDimensions

    return
        $ ( string (dColNoFormat d)
             $ (replicate (lNoWidth + 3) ' ')
            ++ ( take (txtCols + 1)
               $ drop scrollCols
               $ (' ':)
               $ concat
               $ map ( padRight (dColNoInterval d) ' '
                     . show
                     )
                 [1, dColNoInterval d + 1 ..]
               )
          )
       <-> string (dFrameFormat d)
            ( replicate (lNoWidth + 2) ' '
           ++ "+"
           ++ ( take (txtCols + 1)
              $ drop scrollCols
              $ ('-':)
              $ cycle
              $ 'v' : replicate (dColNoInterval d - 1) '-'
              )
            )



-- | Creates the left border of the interface.
makeLineNos :: WSEdit Image
makeLineNos = do
    s <- get
    d <- edDesign <$> ask
    lNoWidth <- lineNoWidth

    (scrollRows, _) <- getOffset
    (r         , _) <- getCursor
    (txtRows   , _)<- getViewportDimensions

    return $ vertCat
           $ map (\n -> char (dLineNoFormat d) ' '
                    <|> ( string (if r == n && not (readOnly s)
                                     then dCurrLnMod d $ dLineNoFormat d
                                     else if n `mod` dLineNoInterv d == 0
                                             then dLineNoFormat d
                                             else dFrameFormat  d
                                 )
                        $ padLeft lNoWidth ' '
                        $ if n <= B.length (edLines s)
                             then if n `mod` dLineNoInterv d == 0
                                    || r == n
                                     then show n
                                     else "·"
                             else ""
                        )
                    <|> string (dFrameFormat d) " |"
                 )
             [scrollRows + 1, scrollRows + 2 .. scrollRows + txtRows]



-- | Creates the bottom border of the interface.
makeFooter :: WSEdit Image
makeFooter = do
    s <- get
    d <- edDesign <$> ask

    lNoWidth <- lineNoWidth

    (_         , txtCols) <- getViewportDimensions
    (_         ,   nCols) <- getDisplayBounds
    (r         , c      ) <- getCursor

    return $ string (dFrameFormat d)
                ( replicate (lNoWidth + 2) ' '
               ++ "+-------+"
               ++ replicate (txtCols - 6) '-'
                )
          <-> (  string (dFrameFormat d)
                (replicate lNoWidth ' ' ++ "  | ")
             <|> string (dFrameFormat d)
                ( (if replaceTabs s
                      then "SPC "
                      else "TAB "
                  )
               ++ (if readOnly s
                      then "R "
                      else "W "
                  )
               ++ "| "
                )
             <|> string (dFrameFormat d)
                ( fname s
               ++ (if changed s
                      then "*"
                      else " "
                  )
               ++ if readOnly s
                     then ""
                     else ( case markPos s of
                                 Nothing -> ""
                                 Just  m -> show m
                                         ++ " -> "
                          )
               ++ show (r, c)
               ++ " "
                )
             <|> string (dStatusFormat d) (padRight nCols ' ' $ status s)
              )



-- | Assembles the entire interface frame.
makeFrame :: WSEdit Image
makeFrame = do
    h <- makeHeader
    l <- makeLineNos
    f <- makeFooter
    return $ h <-> l <-> f



-- | Render the current text window.
makeTextFrame :: WSEdit Image
makeTextFrame = do
    s <- get
    d <- edDesign <$> ask
    lNoWidth <- lineNoWidth

    (scrollRows, scrollCols) <- getOffset
    (   txtRows, _         ) <- getViewportDimensions

    txt <- mapM (uncurry (stringRep 0))
         $ zip [(x,1) | x <- [1 + scrollRows ..]]
         $ B.sub scrollRows (scrollRows + txtRows - 1)
         $ edLines s

    return $ pad (lNoWidth + 3) 2 0 0
           $ vertCat
           $ map ( (char (dLineNoFormat d) ' ' <|>)
                 . translateX (-scrollCols)
                 . pad 0 0 (scrollCols + 1) 0
                 . if drawBg s
                      then id
                      else (<|> char ( fromJust
                                     $ lookup Whitesp
                                     $ dCharStyles d
                                     ) (dBGChar d)
                           )
                 )
             txt



-- | Render the background.
makeBackground :: WSEdit Image
makeBackground = do
    conf <- ask

    (nRows, nCols     ) <- getDisplayBounds
    (_    , scrollCols) <- getOffset

    cursor   <- getCursor >>= toCursorDispPos
    lNoWidth <- lineNoWidth

    let
        bgChar  =                    dBGChar    $ edDesign conf
        bgSty   =                    dBGFormat  $ edDesign conf
        colChar = fromMaybe bgChar $ dColChar   $ edDesign conf

    return $ pad(lNoWidth + 3) 0 0 0
           $ vertCat
           $ map (\(n, l) -> string (if n == fst cursor
                                          then bgSty `withStyle` reverseVideo
                                          else bgSty
                                    ) l
                 )
           $ take nRows
           $ zip [0..]
           $ repeat
           $ ('#' :)
           $ take nCols
           $ drop scrollCols
           $ cycle
           $ colChar
           : replicate (dColNoInterval (edDesign conf) - 1) bgChar



-- | Draws everything.
draw :: WSEdit ()
draw = do
    s    <- get
    conf <- ask

    cursor <- getCursor >>= toCursorDispPos

    frame <- makeFrame
    txt   <- makeTextFrame
    bg    <- if drawBg s
                then makeBackground
                else return undefined

    liftIO $ update (vtyObj conf)
             Picture
                { picCursor     = if readOnly s
                                     then NoCursor
                                     else uncurry Cursor $ swap cursor
                , picLayers     = if drawBg s
                                     then [ frame
                                          , txt
                                          , bg
                                          ]
                                     else [ frame
                                          , txt
                                          ]
                , picBackground = ClearBackground
                }