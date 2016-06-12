{-# LANGUAGE LambdaCase #-}

module WSEdit.Data
    ( EdState (..)
    , getCursor
    , setCursor
    , getMark
    , setMark
    , clearMark
    , getFirstSelected
    , getLastSelected
    , getOffset
    , setOffset
    , setStatus
    , alter
    , popHist
    , getSelection
    , delSelection
    , getDisplayBounds
    , EdConfig (..)
    , mkDefConfig
    , EdDesign (..)
    , brightTheme
    , WSEdit
    , catchEditor
    , Keymap
    ) where


import Control.Exception        (SomeException, evaluate, try)
import Control.Monad.IO.Class   (liftIO)
import Control.Monad.RWS.Strict (RWST, ask, get, modify, put, runRWST)
import Data.Default             (Default (def))
import Data.Maybe               (fromJust, fromMaybe, isJust)
import Data.Tuple               (swap)
import Graphics.Vty             ( Attr
                                , Event
                                , Vty (outputIface)
                                , black, blue, bold, green, defAttr
                                , displayBounds, green, magenta, red, white
                                , withBackColor, withForeColor, withStyle
                                , yellow
                                )

import WSEdit.Util              (CharClass ( Bracket, Digit, Lower, Operator
                                           , Special, Upper, Whitesp
                                           )
                                )
import WSEdit.WordTree          (WordTree, empty)

import qualified WSEdit.Buffer as B



-- | Editor state container (dynamic part).
data EdState = EdState
    { edLines      :: B.Buffer String
        -- ^ Buffer of lines. The current line is always left of the current
        --   position.

    , fname        :: FilePath
        -- ^ Path of the current file.

    , readOnly     :: Bool
        -- ^ Whether the file is opened in read only mode. Has no relation to
        --   the write permissions on the actual file.


    , cursorPos    :: Int
        -- ^ 1-based offset from the left end of the current line in characters.

    , wantsPos     :: Maybe Int
        -- ^ Target visual position (1-based offset in columns) of the cursor.
        --   Used to implement the cursor vertically moving over empty lines
        --   without resetting to column 1.  (It's hard to explain, see
        --   'WSEdit.Control.Base.moveCursor'.)

    , markPos      :: Maybe (Int, Int)
        -- ^ Selection mark position.

    , scrollOffset :: (Int, Int)
        -- ^ Viewport offset, 0-based.


    , continue     :: Bool
        -- ^ Whether the main loop should continue past this iteration.

    , status       :: String
        -- ^ Status string displayed at the bottom.


    , changed      :: Bool
        -- ^ Whether the file has been changed since the last load/save.

    , history      :: Maybe EdState
        -- ^ Editor state prior to the last action, used to implement undo
        --   facilities.  Horrible memory efficiency, but it seems to work.


    , buildDict    :: Maybe Int
        -- ^ Whether the editor is to build a dictionary, and if yes, at which
        --   indentation depth.

    , dict         :: WordTree
        -- ^ Autocompletion dictionary.

    , canComplete  :: Bool
        -- ^ Whether the autocomplete function can be invoked at this moment
        --   (usually 'True' while the user is typing and 'False' while he's
        --   scrolling).

    , replaceTabs  :: Bool
        -- ^ Whether to insert spaces instead of tabs. Has no effect on existing
        --   indentation.

    , detectTabs   :: Bool
        -- ^ Whether to autodetect the 'replaceTabs' setting on each load based
        --   on the file's existing indentation.
    }
    deriving (Show)

instance Default EdState where
    def = EdState
        { edLines      = B.singleton ""
        , fname        = ""
        , readOnly     = False

        , cursorPos    = 1
        , wantsPos     = Nothing
        , markPos      = Nothing
        , scrollOffset = (0, 0)

        , continue     = True
        , status       = ""

        , changed      = False
        , history      = Nothing

        , buildDict    = Nothing
        , dict         = empty
        , canComplete  = False
        , replaceTabs  = False
        , detectTabs   = True
        }


-- | Retrieve the current cursor position.
getCursor :: WSEdit (Int, Int)
getCursor = do
    s <- get
    return (B.currPos $ edLines s, cursorPos s)

-- | Set the current cursor position.
setCursor :: (Int, Int) -> WSEdit ()
setCursor (r, c) = do
    s <- get
    put $ s { cursorPos = c
            , edLines   = B.moveTo r $ edLines s
            }


-- | Retrieve the current mark position, if it exists.
getMark :: WSEdit (Maybe (Int, Int))
getMark = markPos <$> get


-- | Set the mark to a position.
setMark :: (Int, Int) -> WSEdit ()
setMark p = do
    s <- get
    put $ s { markPos = Just p }

-- | Clear a previously set mark.
clearMark :: WSEdit ()
clearMark = do
    s <- get
    put $ s { markPos = Nothing }



-- | Retrieve the position of the first selected element.
getFirstSelected :: WSEdit (Maybe (Int, Int))
getFirstSelected =
    getMark >>= \case
        Nothing       -> return Nothing
        Just (mR, mC) -> do
            (cR, cC) <- getCursor

            case compare mR cR of
                 LT -> return $ Just (mR, mC)
                 GT -> return $ Just (cR, cC)
                 EQ ->
                    case compare mC cC of
                         LT -> return $ Just (mR, mC)
                         GT -> return $ Just (cR, cC)
                         EQ -> return Nothing


-- | Retrieve the position of the last selected element.
getLastSelected :: WSEdit (Maybe (Int, Int))
getLastSelected =
    getMark >>= \case
        Nothing -> return Nothing
        Just (mR, mC) -> do
            (cR, cC) <- getCursor

            case compare mR cR of
                 LT -> return $ Just (cR, cC - 1)
                 GT -> return $ Just (mR, mC - 1)
                 EQ ->
                    case compare mC cC of
                         LT -> return $ Just (cR, cC - 1)
                         GT -> return $ Just (mR, mC - 1)
                         EQ -> return Nothing



-- | Retrieve the current viewport offset (relative to the start of the file).
getOffset :: WSEdit (Int, Int)
getOffset = scrollOffset <$> get

-- | Set the viewport offset.
setOffset :: (Int, Int) -> WSEdit ()
setOffset p = do
    s <- get
    put $ s { scrollOffset = p }



-- | Set the status line's contents.
setStatus :: String -> WSEdit ()
setStatus st = do
    s <- get

    -- Precaution, since lazyness can be quirky sometimes
    st' <- liftIO $ evaluate st

    put $ s { status = st' }



-- | Create an undo checkpoint and set the changed flag.
alter :: WSEdit ()
alter = do
    h <- histSize <$> ask
    modify (\s -> s { history = chopHist h (Just s)
                    , changed = True
                    } )
    where
        -- | The 'EdState' 'history' is structured like a conventional list, and
        --   this is its 'take', with some added 'Maybe'ness.
        chopHist :: Int -> Maybe EdState -> Maybe EdState
        chopHist n _        | n <= 0 = Nothing
        chopHist _ Nothing           = Nothing
        chopHist n (Just s)          =
            Just $ s { history = chopHist (n-1) (history s) }


-- | Restore the last undo checkpoint, if available.
popHist :: WSEdit ()
popHist = modify popHist'

    where
        -- | The 'EdState' 'history' is structured like a conventional list, and
        --   this is its 'tail'.
        popHist' :: EdState -> EdState
        popHist' s = fromMaybe s $ history s



-- | Retrieve the contents of the current selection.
getSelection :: WSEdit (Maybe String)
getSelection = do
    b <- isJust . markPos <$> get
    if not b
       then return Nothing
       else do
            (sR, sC) <- fromJust <$> getFirstSelected
            (eR, eC) <- fromJust <$> getLastSelected
            l <- edLines <$> get

            if sR == eR
               then return $ Just
                           $ drop (sC - 1)
                           $ take eC
                           $ fromJust
                           $ B.left l

               else
                    let
                        lns = B.sub (sR - 1) (eR - 1) l
                    in
                        return $ Just
                               $ drop (sC - 1) (head lns) ++ "\n"
                              ++ unlines (tail $ init lns)
                              ++ take eC (last lns)



-- | Delete the contents of the current selection from the text buffer.
delSelection :: WSEdit Bool
delSelection = do
    b <- isJust . markPos <$> get
    if not b
       then return False
       else do
            (_ , sC) <- fromJust <$> getFirstSelected
            (_ , eC) <- fromJust <$> getLastSelected

            (mR, mC) <- fromJust <$> getMark
            (cR, cC) <- getCursor

            s <- get

            case compare mR cR of
                 EQ -> do
                    put $ s { edLines   = fromJust
                                        $ B.withLeft (\l -> take (sC - 1) l
                                                         ++ drop  eC      l
                                                     )
                                        $ edLines s
                            , cursorPos = sC
                            }
                    return True

                 LT -> do
                    put $ s { edLines   = fromJust
                                        $ B.withLeft (\l -> take (mC - 1) l
                                                         ++ drop (cC - 1)
                                                              ( fromJust
                                                              $ B.left
                                                              $ edLines s
                                                              )
                                                     )
                                        $ B.dropLeft (cR - mR)
                                        $ edLines s
                            , cursorPos = sC
                            }
                    return True

                 GT ->
                    let
                        b' = B.dropRight (mR - cR - 1)
                           $ edLines s
                    in do
                        put $ s { edLines   = fromJust
                                            $ B.withLeft (\l -> take (cC - 1) l
                                                             ++ drop (mC - 1)
                                                                  (fromMaybe ""
                                                                  $ B.right b'
                                                                  )
                                                         )
                                            $ B.deleteRight b'
                                , cursorPos = sC
                                }
                        return True



-- | Retrieve the number of rows, colums displayed by vty, including all borders
--   , frames and similar woo.
getDisplayBounds :: WSEdit (Int, Int)
getDisplayBounds = ask
               >>= displayBounds . outputIface . vtyObj
               >>= return . swap





-- | Editor configuration container (static part).
data EdConfig = EdConfig
    { vtyObj     :: Vty
        -- ^ vty object container, used to issue draw calls and receive events.

    , edDesign   :: EdDesign
        -- ^ Design object, see below.

    , keymap     :: Keymap
        -- ^ What to do when a button is pressed. Inserting a character when the
        --   corresponding key is pressed (e.g. 'a') is not included here, but
        --   may be overridden with this table. (Why would you want to do that?)

    , histSize   :: Int
        -- ^ Number of undo states to keep.

    , tabWidth   :: Int
        -- ^ Width of a tab character.

    , drawBg     :: Bool
        -- ^ Whether or not to draw the background.

    , dumpEvents :: Bool
        -- ^ Whether or not to dump every received event to the status line.

    , purgeOnClose :: Bool
        -- ^ Whether the clipboard file is to be deleted on close.
    }

-- | Create a default `EdConfig`.
mkDefConfig :: Vty -> Keymap -> EdConfig
mkDefConfig v k = EdConfig
                { vtyObj       = v
                , edDesign     = def
                , keymap       = k
                , histSize     = 100
                , tabWidth     = 4
                , drawBg       = True
                , dumpEvents   = False
                , purgeOnClose = False
              }





-- | Design portion of the editor configuration.
data EdDesign = EdDesign
    { dFrameFormat   :: Attr
        -- ^ vty attribute for the frame lines

    , dStatusFormat  :: Attr
        -- ^ vty attribute for the status line


    , dLineNoFormat  :: Attr
        -- ^ vty attribute for the line numbers to the left

    , dLineNoInterv  :: Int
        -- ^ Display interval for the line numbers


    , dColNoInterval :: Int
        -- ^ Display interval for the column numbers. Don't set this lower than
        --   the expected number's length, or strange things might happen.

    , dColNoFormat   :: Attr
        -- ^ vty attribute for the column numbers


    , dBGChar        :: Char
        -- ^ Character to fill the background with

    , dColChar       :: Maybe Char
        -- ^ Character to draw column lines with

    , dBGFormat      :: Attr
        -- ^ vty attribute for everything in the background


    , dCurrLnMod     :: Attr -> Attr
        -- ^ Attribute modifications to apply to the current line


    , dTabStr        :: String
        -- ^ String to display tab characters as. Will get truncated from the
        --   left as needed. Make sure this is at least as long as your intended
        --   indentation width (wsedit supports a maximum of 9).

    , dSelFormat     :: Attr
        -- ^ vty attribute for selected text

    , dCharStyles    :: [(CharClass, Attr)]
    }


instance Default EdDesign where
    def = EdDesign
        { dFrameFormat   = defAttr
                            `withForeColor` green

        , dStatusFormat  = defAttr
                            `withForeColor` green
                            `withStyle`     bold

        , dLineNoFormat  = defAttr
                            `withForeColor` green
                            `withStyle`     bold
        , dLineNoInterv  = 10

        , dColNoInterval = 40
        , dColNoFormat   = defAttr
                            `withForeColor` green
                            `withStyle`     bold

        , dBGChar        = '·'
        , dColChar       = Just '|'
        , dBGFormat      = defAttr
                            `withForeColor` black

        , dCurrLnMod     = flip withBackColor black

        , dTabStr        = "        |"

        , dSelFormat     = defAttr
                            `withForeColor` black
                            `withBackColor` white

        , dCharStyles    =
            [ (Whitesp , defAttr
                            `withForeColor` blue
              )
            , (Digit   , defAttr
                            `withForeColor` red
              )
            , (Lower   , defAttr
              )
            , (Upper   , defAttr
                            `withStyle`     bold
              )
            , (Bracket , defAttr
                            `withForeColor` yellow
              )
            , (Operator, defAttr
                            `withForeColor` yellow
                            `withStyle`     bold
              )
            , (Special , defAttr
                            `withForeColor` red
                            `withStyle`     bold
              )
            ]

        }



brightTheme:: EdDesign
brightTheme = EdDesign
        { dFrameFormat   = defAttr
                            `withForeColor` green

        , dStatusFormat  = defAttr
                            `withForeColor` green
                            `withStyle`     bold

        , dLineNoFormat  = defAttr
                            `withForeColor` green
                            `withStyle`     bold
        , dLineNoInterv  = 10

        , dColNoInterval = 40
        , dColNoFormat   = defAttr
                            `withForeColor` green
                            `withStyle`     bold

        , dBGChar        = '·'
        , dColChar       = Just '|'
        , dBGFormat      = defAttr
                            `withForeColor` white

        , dCurrLnMod     = flip withBackColor white

        , dTabStr        = "        |"

        , dSelFormat     = defAttr
                            `withForeColor` white
                            `withBackColor` black

        , dCharStyles    =
            [ (Whitesp , defAttr
                            `withForeColor` blue
              )
            , (Digit   , defAttr
                            `withForeColor` red
              )
            , (Lower   , defAttr
              )
            , (Upper   , defAttr
                            `withStyle`     bold
              )
            , (Bracket , defAttr
                            `withForeColor` magenta
              )
            , (Operator, defAttr
                            `withForeColor` magenta
                            `withStyle`     bold
              )
            , (Special , defAttr
                            `withForeColor` red
                            `withStyle`     bold
              )
            ]

        }



-- | Editor monad. Reads an 'EdConfig', writes nothing, alters an 'EdState'.
type WSEdit = RWST EdConfig () EdState IO



-- | Lifted version of 'catch' typed to 'SomeException'.
catchEditor :: WSEdit a -> (SomeException -> WSEdit a) -> WSEdit a
catchEditor a e = do
    c <- ask
    s <- get
    (r, s') <- liftIO $ try (runRWST a c s) >>= \case
                    Right (r, s', _) -> return (r, s')
                    Left  err        -> do
                        (r, s', _) <- runRWST (e err) c s
                        return (r, s')
    put s'
    return r



-- | Map of events to actions.
type Keymap = [(Event, WSEdit ())]
