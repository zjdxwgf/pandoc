{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE ViewPatterns     #-}
{-
Copyright (C) 2014-2017 Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Readers.Org.Options
   Copyright   : Copyright (C) 2014-2017 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>

Parsers for Org-mode block elements.
-}
module Text.Pandoc.Readers.Org.Blocks
  ( blockList
  , meta
  ) where

import Text.Pandoc.Readers.Org.BlockStarts
import Text.Pandoc.Readers.Org.Inlines
import Text.Pandoc.Readers.Org.Meta (metaExport, metaKey, metaLine)
import Text.Pandoc.Readers.Org.ParserState
import Text.Pandoc.Readers.Org.Parsing
import Text.Pandoc.Readers.Org.Shared (cleanLinkString, isImageFilename,
                                       originalLang, translateLang)

import Text.Pandoc.Builder (Blocks, Inlines)
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Class (PandocMonad)
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Shared (compactify, compactifyDL, safeRead)

import Control.Monad (foldM, guard, mzero, void)
import Data.Char (isSpace, toLower, toUpper)
import Data.Default (Default)
import Data.List (foldl', isPrefixOf)
import Data.Maybe (fromMaybe, isNothing)
import Data.Monoid ((<>))

--
-- Org headers
--
newtype Tag = Tag { fromTag :: String }
  deriving (Show, Eq)

-- | Create a tag containing the given string.
toTag :: String -> Tag
toTag = Tag

-- | The key (also called name or type) of a property.
newtype PropertyKey = PropertyKey { fromKey :: String }
  deriving (Show, Eq, Ord)

-- | Create a property key containing the given string.  Org mode keys are
-- case insensitive and are hence converted to lower case.
toPropertyKey :: String -> PropertyKey
toPropertyKey = PropertyKey . map toLower

-- | The value assigned to a property.
newtype PropertyValue = PropertyValue { fromValue :: String }

-- | Create a property value containing the given string.
toPropertyValue :: String -> PropertyValue
toPropertyValue = PropertyValue

-- | Check whether the property value is non-nil (i.e. truish).
isNonNil :: PropertyValue -> Bool
isNonNil p = map toLower (fromValue p) `notElem` ["()", "{}", "nil"]

-- | Key/value pairs from a PROPERTIES drawer
type Properties = [(PropertyKey, PropertyValue)]

-- | Org mode headline (i.e. a document subtree).
data Headline = Headline
  { headlineLevel      :: Int
  , headlineTodoMarker :: Maybe TodoMarker
  , headlineText       :: Inlines
  , headlineTags       :: [Tag]
  , headlineProperties :: Properties
  , headlineContents   :: Blocks
  , headlineChildren   :: [Headline]
  }

--
-- Parsing headlines and subtrees
--

-- | Read an Org mode headline and its contents (i.e. a document subtree).
-- @lvl@ gives the minimum acceptable level of the tree.
headline :: PandocMonad m => Int -> OrgParser m (F Headline)
headline lvl = try $ do
  level <- headerStart
  guard (lvl <= level)
  todoKw <- optionMaybe todoKeyword
  title <- trimInlinesF . mconcat <$> manyTill inline endOfTitle
  tags  <- option [] headerTags
  newline
  properties <- option mempty propertiesDrawer
  contents   <- blocks
  children   <- many (headline (level + 1))
  return $ do
    title'    <- title
    contents' <- contents
    children' <- sequence children
    return $ Headline
      { headlineLevel = level
      , headlineTodoMarker = todoKw
      , headlineText = title'
      , headlineTags = tags
      , headlineProperties = properties
      , headlineContents = contents'
      , headlineChildren = children'
      }
 where
   endOfTitle :: Monad m => OrgParser m ()
   endOfTitle = void . lookAhead $ optional headerTags *> newline

   headerTags :: Monad m => OrgParser m [Tag]
   headerTags = try $
     let tag = many1 (alphaNum <|> oneOf "@%#_") <* char ':'
     in map toTag <$> (skipSpaces *> char ':' *> many1 tag <* skipSpaces)

-- | Convert an Org mode headline (i.e. a document tree) into pandoc's Blocks
headlineToBlocks :: Monad m => Headline -> OrgParser m Blocks
headlineToBlocks hdln@(Headline {..}) = do
  maxHeadlineLevels <- getExportSetting exportHeadlineLevels
  case () of
    _ | any isNoExportTag headlineTags     -> return mempty
    _ | any isArchiveTag  headlineTags     -> archivedHeadlineToBlocks hdln
    _ | isCommentTitle headlineText        -> return mempty
    _ | headlineLevel >= maxHeadlineLevels -> headlineToHeaderWithList hdln
    _ | otherwise                          -> headlineToHeaderWithContents hdln

isNoExportTag :: Tag -> Bool
isNoExportTag = (== toTag "noexport")

isArchiveTag :: Tag -> Bool
isArchiveTag = (== toTag "ARCHIVE")

-- | Check if the title starts with COMMENT.
-- FIXME: This accesses builder internals not intended for use in situations
-- like these.  Replace once keyword parsing is supported.
isCommentTitle :: Inlines -> Bool
isCommentTitle (B.toList -> (Str "COMMENT":_)) = True
isCommentTitle _                               = False

archivedHeadlineToBlocks :: Monad m => Headline -> OrgParser m Blocks
archivedHeadlineToBlocks hdln = do
  archivedTreesOption <- getExportSetting exportArchivedTrees
  case archivedTreesOption of
    ArchivedTreesNoExport     -> return mempty
    ArchivedTreesExport       -> headlineToHeaderWithContents hdln
    ArchivedTreesHeadlineOnly -> headlineToHeader hdln

headlineToHeaderWithList :: Monad m => Headline -> OrgParser m Blocks
headlineToHeaderWithList hdln@(Headline {..}) = do
  maxHeadlineLevels <- getExportSetting exportHeadlineLevels
  header        <- headlineToHeader hdln
  listElements  <- sequence (map headlineToBlocks headlineChildren)
  let listBlock  = if null listElements
                   then mempty
                   else B.orderedList listElements
  let headerText = if maxHeadlineLevels == headlineLevel
                   then header
                   else flattenHeader header
  return $ headerText <> headlineContents <> listBlock
 where
   flattenHeader :: Blocks -> Blocks
   flattenHeader blks =
     case B.toList blks of
       (Header _ _ inlns:_) -> B.para (B.fromList inlns)
       _                    -> mempty

headlineToHeaderWithContents :: Monad m => Headline -> OrgParser m Blocks
headlineToHeaderWithContents hdln@(Headline {..}) = do
  header         <- headlineToHeader hdln
  childrenBlocks <- mconcat <$> sequence (map headlineToBlocks headlineChildren)
  return $ header <> headlineContents <> childrenBlocks

headlineToHeader :: Monad m => Headline -> OrgParser m Blocks
headlineToHeader (Headline {..}) = do
  exportTodoKeyword <- getExportSetting exportWithTodoKeywords
  let todoText    = if exportTodoKeyword
                    then case headlineTodoMarker of
                      Just kw -> todoKeywordToInlines kw <> B.space
                      Nothing -> mempty
                    else mempty
  let text        = tagTitle (todoText <> headlineText) headlineTags
  let propAttr    = propertiesToAttr headlineProperties
  attr           <- registerHeader propAttr headlineText
  return $ B.headerWith attr headlineLevel text

todoKeyword :: Monad m => OrgParser m TodoMarker
todoKeyword = try $ do
  taskStates <- activeTodoMarkers <$> getState
  let kwParser tdm = try $ (tdm <$ string (todoMarkerName tdm) <* spaceChar)
  choice (map kwParser taskStates)

todoKeywordToInlines :: TodoMarker -> Inlines
todoKeywordToInlines tdm =
  let todoText  = todoMarkerName tdm
      todoState = map toLower . show $ todoMarkerState tdm
      classes = [todoState, todoText]
  in B.spanWith (mempty, classes, mempty) (B.str todoText)

propertiesToAttr :: Properties -> Attr
propertiesToAttr properties =
  let
    toStringPair prop = (fromKey (fst prop), fromValue (snd prop))
    customIdKey = toPropertyKey "custom_id"
    classKey    = toPropertyKey "class"
    unnumberedKey = toPropertyKey "unnumbered"
    specialProperties = [customIdKey, classKey, unnumberedKey]
    id'  = fromMaybe mempty . fmap fromValue . lookup customIdKey $ properties
    cls  = fromMaybe mempty . fmap fromValue . lookup classKey    $ properties
    kvs' = map toStringPair . filter ((`notElem` specialProperties) . fst)
           $ properties
    isUnnumbered =
      fromMaybe False . fmap isNonNil . lookup unnumberedKey $ properties
  in
    (id', words cls ++ (if isUnnumbered then ["unnumbered"] else []), kvs')

tagTitle :: Inlines -> [Tag] -> Inlines
tagTitle title tags = title <> (mconcat $ map tagToInline tags)

tagToInline :: Tag -> Inlines
tagToInline t = B.spanWith ("", ["tag"], [("data-tag-name", fromTag t)]) mempty


--
-- parsing blocks
--

-- | Get a list of blocks.
blockList :: PandocMonad m => OrgParser m [Block]
blockList = do
  initialBlocks  <- blocks
  headlines      <- sequence <$> manyTill (headline 1) eof
  st             <- getState
  headlineBlocks <- fmap mconcat . sequence . map headlineToBlocks $ runF headlines st
  return . B.toList $ (runF initialBlocks st) <> headlineBlocks

-- | Get the meta information saved in the state.
meta :: Monad m => OrgParser m Meta
meta = do
  meta' <- metaExport
  runF meta' <$> getState

blocks :: PandocMonad m => OrgParser m (F Blocks)
blocks = mconcat <$> manyTill block (void (lookAhead headerStart) <|> eof)

block :: PandocMonad m => OrgParser m (F Blocks)
block = choice [ mempty <$ blanklines
               , table
               , orgBlock
               , figure
               , example
               , genericDrawer
               , specialLine
               , horizontalRule
               , list
               , latexFragment
               , noteBlock
               , paraOrPlain
               ] <?> "block"


-- | Parse a horizontal rule into a block element
horizontalRule :: Monad m => OrgParser m (F Blocks)
horizontalRule = return B.horizontalRule <$ try hline


--
-- Block Attributes
--

-- | Attributes that may be added to figures (like a name or caption).
data BlockAttributes = BlockAttributes
  { blockAttrName      :: Maybe String
  , blockAttrLabel     :: Maybe String
  , blockAttrCaption   :: Maybe (F Inlines)
  , blockAttrKeyValues :: [(String, String)]
  }

-- | Convert BlockAttributes into pandoc Attr
attrFromBlockAttributes :: BlockAttributes -> Attr
attrFromBlockAttributes (BlockAttributes{..}) =
  let
    ident   = fromMaybe mempty $ lookup "id" blockAttrKeyValues
    classes = case lookup "class" blockAttrKeyValues of
                Nothing     -> []
                Just clsStr -> words clsStr
    kv      = filter ((`notElem` ["id", "class"]) . fst) blockAttrKeyValues
  in (ident, classes, kv)

stringyMetaAttribute :: Monad m => (String -> Bool) -> OrgParser m (String, String)
stringyMetaAttribute attrCheck = try $ do
  metaLineStart
  attrName <- map toUpper <$> many1Till nonspaceChar (char ':')
  guard $ attrCheck attrName
  skipSpaces
  attrValue <- anyLine
  return (attrName, attrValue)

blockAttributes :: PandocMonad m => OrgParser m BlockAttributes
blockAttributes = try $ do
  kv <- many (stringyMetaAttribute attrCheck)
  let caption = foldl' (appendValues "CAPTION") Nothing kv
  let kvAttrs = foldl' (appendValues "ATTR_HTML") Nothing kv
  let name    = lookup "NAME" kv
  let label   = lookup "LABEL" kv
  caption' <- case caption of
                   Nothing -> return Nothing
                   Just s  -> Just <$> parseFromString inlines (s ++ "\n")
  kvAttrs' <- parseFromString keyValues . (++ "\n") $ fromMaybe mempty kvAttrs
  return $ BlockAttributes
           { blockAttrName = name
           , blockAttrLabel = label
           , blockAttrCaption = caption'
           , blockAttrKeyValues = kvAttrs'
           }
 where
   attrCheck :: String -> Bool
   attrCheck attr =
     case attr of
       "NAME"      -> True
       "LABEL"     -> True
       "CAPTION"   -> True
       "ATTR_HTML" -> True
       _           -> False

   appendValues :: String -> Maybe String -> (String, String) -> Maybe String
   appendValues attrName accValue (key, value) =
     if key /= attrName
     then accValue
     else case accValue of
            Just acc -> Just $ acc ++ ' ':value
            Nothing  -> Just value

keyValues :: Monad m => OrgParser m [(String, String)]
keyValues = try $
  manyTill ((,) <$> key <*> value) newline
 where
   key :: Monad m => OrgParser m String
   key = try $ skipSpaces *> char ':' *> many1 nonspaceChar

   value :: Monad m => OrgParser m String
   value = skipSpaces *> manyTill anyChar endOfValue

   endOfValue :: Monad m => OrgParser m ()
   endOfValue =
     lookAhead $ (() <$ try (many1 spaceChar <* key))
              <|> () <$ newline


--
-- Org Blocks (#+BEGIN_... / #+END_...)
--

-- | Read an org-mode block delimited by #+BEGIN_TYPE and #+END_TYPE.
orgBlock :: PandocMonad m => OrgParser m (F Blocks)
orgBlock = try $ do
  blockAttrs <- blockAttributes
  blkType <- blockHeaderStart
  ($ blkType) $
    case (map toLower blkType) of
      "export"  -> exportBlock
      "comment" -> rawBlockLines (const mempty)
      "html"    -> rawBlockLines (return . B.rawBlock (lowercase blkType))
      "latex"   -> rawBlockLines (return . B.rawBlock (lowercase blkType))
      "ascii"   -> rawBlockLines (return . B.rawBlock (lowercase blkType))
      "example" -> rawBlockLines (return . exampleCode)
      "quote"   -> parseBlockLines (fmap B.blockQuote)
      "verse"   -> verseBlock
      "src"     -> codeBlock blockAttrs
      _         -> parseBlockLines $
                   let (ident, classes, kv) = attrFromBlockAttributes blockAttrs
                   in fmap $ B.divWith (ident, classes ++ [blkType], kv)
 where
   blockHeaderStart :: Monad m => OrgParser m String
   blockHeaderStart = try $ skipSpaces *> stringAnyCase "#+begin_" *> orgArgWord

   lowercase :: String -> String
   lowercase = map toLower

rawBlockLines :: Monad m => (String   -> F Blocks) -> String -> OrgParser m (F Blocks)
rawBlockLines f blockType = (ignHeaders *> (f <$> rawBlockContent blockType))

parseBlockLines :: PandocMonad m => (F Blocks -> F Blocks) -> String -> OrgParser m (F Blocks)
parseBlockLines f blockType = (ignHeaders *> (f <$> parsedBlockContent))
 where
   parsedBlockContent :: PandocMonad m => OrgParser m (F Blocks)
   parsedBlockContent = try $ do
     raw <- rawBlockContent blockType
     parseFromString blocks (raw ++ "\n")

-- | Read the raw string content of a block
rawBlockContent :: Monad m => String -> OrgParser m String
rawBlockContent blockType = try $ do
  blkLines <- manyTill rawLine blockEnder
  tabLen <- getOption readerTabStop
  return
    . unlines
    . stripIndent
    . map (tabsToSpaces tabLen . commaEscaped)
    $ blkLines
 where
   rawLine :: Monad m => OrgParser m String
   rawLine = try $ ("" <$ blankline) <|> anyLine

   blockEnder :: Monad m => OrgParser m ()
   blockEnder = try $ skipSpaces <* stringAnyCase ("#+end_" <> blockType)

   stripIndent :: [String] -> [String]
   stripIndent strs = map (drop (shortestIndent strs)) strs

   shortestIndent :: [String] -> Int
   shortestIndent = foldr min maxBound
                    . map (length . takeWhile isSpace)
                    . filter (not . null)

   tabsToSpaces :: Int -> String -> String
   tabsToSpaces _      []         = []
   tabsToSpaces tabLen cs'@(c:cs) =
       case c of
         ' '  -> ' ':tabsToSpaces tabLen cs
         '\t' -> (take tabLen $ repeat ' ') ++ tabsToSpaces tabLen cs
         _    -> cs'

   commaEscaped :: String -> String
   commaEscaped (',':cs@('*':_))     = cs
   commaEscaped (',':cs@('#':'+':_)) = cs
   commaEscaped (' ':cs)             = ' ':commaEscaped cs
   commaEscaped ('\t':cs)            = '\t':commaEscaped cs
   commaEscaped cs                   = cs

-- | Read but ignore all remaining block headers.
ignHeaders :: Monad m => OrgParser m ()
ignHeaders = (() <$ newline) <|> (() <$ anyLine)

-- | Read a block containing code intended for export in specific backends
-- only.
exportBlock :: Monad m => String -> OrgParser m (F Blocks)
exportBlock blockType = try $ do
  exportType <- skipSpaces *> orgArgWord <* ignHeaders
  contents   <- rawBlockContent blockType
  returnF (B.rawBlock (map toLower exportType) contents)

verseBlock :: PandocMonad m => String -> OrgParser m (F Blocks)
verseBlock blockType = try $ do
  ignHeaders
  content <- rawBlockContent blockType
  fmap B.lineBlock . sequence
    <$> mapM parseVerseLine (lines content)
 where
   -- replace initial spaces with nonbreaking spaces to preserve
   -- indentation, parse the rest as normal inline
   parseVerseLine :: PandocMonad m => String -> OrgParser m (F Inlines)
   parseVerseLine cs = do
     let (initialSpaces, indentedLine) = span isSpace cs
     let nbspIndent = if null initialSpaces
                      then mempty
                      else B.str $ map (const '\160') initialSpaces
     line <- parseFromString inlines (indentedLine ++ "\n")
     return (trimInlinesF $ pure nbspIndent <> line)

-- | Read a code block and the associated results block if present.  Which of
-- boths blocks is included in the output is determined using the "exports"
-- argument in the block header.
codeBlock :: PandocMonad m => BlockAttributes -> String -> OrgParser m (F Blocks)
codeBlock blockAttrs blockType = do
  skipSpaces
  (classes, kv)     <- codeHeaderArgs <|> (mempty <$ ignHeaders)
  content           <- rawBlockContent blockType
  resultsContent    <- trailingResultsBlock
  let id'            = fromMaybe mempty $ blockAttrName blockAttrs
  let codeBlck       = B.codeBlockWith ( id', classes, kv ) content
  let labelledBlck   = maybe (pure codeBlck)
                             (labelDiv codeBlck)
                             (blockAttrCaption blockAttrs)
  let resultBlck     = fromMaybe mempty resultsContent
  return $
    (if exportsCode kv    then labelledBlck else mempty) <>
    (if exportsResults kv then resultBlck   else mempty)
 where
   labelDiv :: Blocks -> F Inlines -> F Blocks
   labelDiv blk value =
     B.divWith nullAttr <$> (mappend <$> labelledBlock value <*> pure blk)

   labelledBlock :: F Inlines -> F Blocks
   labelledBlock = fmap (B.plain . B.spanWith ("", ["label"], []))

   exportsCode :: [(String, String)] -> Bool
   exportsCode = maybe True (`elem` ["code", "both"]) . lookup "exports"

   exportsResults :: [(String, String)] -> Bool
   exportsResults = maybe False (`elem` ["results", "both"]) . lookup "exports"

trailingResultsBlock :: PandocMonad m => OrgParser m (Maybe (F Blocks))
trailingResultsBlock = optionMaybe . try $ do
  blanklines
  stringAnyCase "#+RESULTS:"
  blankline
  block

-- | Parse code block arguments
codeHeaderArgs :: Monad m => OrgParser m ([String], [(String, String)])
codeHeaderArgs = try $ do
  language   <- skipSpaces *> orgArgWord
  (switchClasses, switchKv) <- switchesAsAttributes
  parameters <- manyTill blockOption newline
  return $ ( translateLang language : switchClasses
           , originalLang language <> switchKv <> parameters
           )

switchesAsAttributes :: Monad m => OrgParser m ([String], [(String, String)])
switchesAsAttributes = try $ do
  switches <- skipSpaces *> (try $ switch `sepBy` (many1 spaceChar))
  return $ foldr addToAttr ([], []) switches
 where
  addToAttr :: (Char, Maybe String, SwitchPolarity)
            -> ([String], [(String, String)])
            -> ([String], [(String, String)])
  addToAttr ('n', lineNum, pol) (cls, kv) =
    let kv' = case lineNum of
                Just num -> (("startFrom", num):kv)
                Nothing  -> kv
        cls' = case pol of
                 SwitchPlus -> "continuedSourceBlock":cls
                 SwitchMinus -> cls
    in ("numberLines":cls', kv')
  addToAttr _ x = x

-- | Whether a switch flag is specified with @+@ or @-@.
data SwitchPolarity = SwitchPlus | SwitchMinus
  deriving (Show, Eq)

-- | Parses a switch's polarity.
switchPolarity :: Monad m => OrgParser m SwitchPolarity
switchPolarity = (SwitchMinus <$ char '-') <|> (SwitchPlus <$ char '+')

-- | Parses a source block switch option.
switch :: Monad m => OrgParser m (Char, Maybe String, SwitchPolarity)
switch = try $ lineNumberSwitch <|> labelSwitch <|> simpleSwitch
 where
   simpleSwitch = (\pol c -> (c, Nothing, pol)) <$> switchPolarity <*> letter
   labelSwitch = genericSwitch 'l' $
     char '"' *> many1Till nonspaceChar (char '"')

-- | Generic source block switch-option parser.
genericSwitch :: Monad m
              => Char
              -> OrgParser m String
              -> OrgParser m (Char, Maybe String, SwitchPolarity)
genericSwitch c p = try $ do
  polarity <- switchPolarity <* char c <* skipSpaces
  arg <- optionMaybe p
  return $ (c, arg, polarity)

-- | Reads a line number switch option. The line number switch can be used with
-- example and source blocks.
lineNumberSwitch :: Monad m => OrgParser m (Char, Maybe String, SwitchPolarity)
lineNumberSwitch = genericSwitch 'n' (many digit)

blockOption :: Monad m => OrgParser m (String, String)
blockOption = try $ do
  argKey <- orgArgKey
  paramValue <- option "yes" orgParamValue
  return (argKey, paramValue)

orgParamValue :: Monad m => OrgParser m String
orgParamValue = try $
  skipSpaces
    *> notFollowedBy orgArgKey
    *> noneOf "\n\r" `many1Till` endOfValue
    <* skipSpaces
 where
  endOfValue = lookAhead $  (try $ skipSpaces <* oneOf "\n\r")
                        <|> (try $ skipSpaces1 <* orgArgKey)


--
-- Drawers
--

-- | A generic drawer which has no special meaning for org-mode.
-- Whether or not this drawer is included in the output depends on the drawers
-- export setting.
genericDrawer :: PandocMonad m => OrgParser m (F Blocks)
genericDrawer = try $ do
  name    <- map toUpper <$> drawerStart
  content <- manyTill drawerLine (try drawerEnd)
  state   <- getState
  -- Include drawer if it is explicitly included in or not explicitly excluded
  -- from the list of drawers that should be exported.  PROPERTIES drawers are
  -- never exported.
  case (exportDrawers . orgStateExportSettings $ state) of
    _           | name == "PROPERTIES" -> return mempty
    Left  names | name `elem`    names -> return mempty
    Right names | name `notElem` names -> return mempty
    _           -> drawerDiv name <$> parseLines content
 where
  parseLines :: PandocMonad m => [String] -> OrgParser m (F Blocks)
  parseLines = parseFromString blocks . (++ "\n") . unlines

  drawerDiv :: String -> F Blocks -> F Blocks
  drawerDiv drawerName = fmap $ B.divWith (mempty, [drawerName, "drawer"], mempty)

drawerLine :: Monad m => OrgParser m String
drawerLine = anyLine

drawerEnd :: Monad m => OrgParser m String
drawerEnd = try $
  skipSpaces *> stringAnyCase ":END:" <* skipSpaces <* newline

-- | Read a :PROPERTIES: drawer and return the key/value pairs contained
-- within.
propertiesDrawer :: Monad m => OrgParser m Properties
propertiesDrawer = try $ do
  drawerType <- drawerStart
  guard $ map toUpper drawerType == "PROPERTIES"
  manyTill property (try drawerEnd)
 where
   property :: Monad m => OrgParser m (PropertyKey, PropertyValue)
   property = try $ (,) <$> key <*> value

   key :: Monad m => OrgParser m PropertyKey
   key = fmap toPropertyKey . try $
         skipSpaces *> char ':' *> many1Till nonspaceChar (char ':')

   value :: Monad m => OrgParser m PropertyValue
   value = fmap toPropertyValue . try $
           skipSpaces *> manyTill anyChar (try $ skipSpaces *> newline)


--
-- Figures
--

-- | Figures or an image paragraph (i.e. an image on a line by itself). Only
-- images with a caption attribute are interpreted as figures.
figure :: PandocMonad m => OrgParser m (F Blocks)
figure = try $ do
  figAttrs <- blockAttributes
  src <- skipSpaces *> selfTarget <* skipSpaces <* endOfParagraph
  case cleanLinkString src of
    Nothing     -> mzero
    Just imgSrc -> do
      guard (isImageFilename imgSrc)
      let isFigure = not . isNothing $ blockAttrCaption figAttrs
      return $ imageBlock isFigure figAttrs imgSrc
 where
   selfTarget :: PandocMonad m => OrgParser m String
   selfTarget = try $ char '[' *> linkTarget <* char ']'

   imageBlock :: Bool -> BlockAttributes -> String -> F Blocks
   imageBlock isFigure figAttrs imgSrc =
     let
       figName    = fromMaybe mempty $ blockAttrName figAttrs
       figLabel   = fromMaybe mempty $ blockAttrLabel figAttrs
       figCaption = fromMaybe mempty $ blockAttrCaption figAttrs
       figKeyVals = blockAttrKeyValues figAttrs
       attr       = (figLabel, mempty, figKeyVals)
       figTitle   = (if isFigure then withFigPrefix else id) figName
     in
       B.para . B.imageWith attr imgSrc figTitle <$> figCaption

   withFigPrefix :: String -> String
   withFigPrefix cs =
     if "fig:" `isPrefixOf` cs
     then cs
     else "fig:" ++ cs

-- | Succeeds if looking at the end of the current paragraph
endOfParagraph :: Monad m => OrgParser m ()
endOfParagraph = try $ skipSpaces *> newline *> endOfBlock


--
-- Examples
--

-- | Example code marked up by a leading colon.
example :: Monad m => OrgParser m (F Blocks)
example = try $ do
  return . return . exampleCode =<< unlines <$> many1 exampleLine
 where
   exampleLine :: Monad m => OrgParser m String
   exampleLine = try $ exampleLineStart *> anyLine

exampleCode :: String -> Blocks
exampleCode = B.codeBlockWith ("", ["example"], [])


--
-- Comments, Options and Metadata
--

specialLine :: PandocMonad m => OrgParser m (F Blocks)
specialLine = fmap return . try $ rawExportLine <|> metaLine <|> commentLine

rawExportLine :: PandocMonad m => OrgParser m Blocks
rawExportLine = try $ do
  metaLineStart
  key <- metaKey
  if key `elem` ["latex", "html", "texinfo", "beamer"]
    then B.rawBlock key <$> anyLine
    else mzero

commentLine :: Monad m => OrgParser m Blocks
commentLine = commentLineStart *> anyLine *> pure mempty


--
-- Tables
--
data ColumnProperty = ColumnProperty
  { columnAlignment :: Maybe Alignment
  , columnRelWidth  :: Maybe Int
  } deriving (Show, Eq)

instance Default ColumnProperty where
  def = ColumnProperty Nothing Nothing

data OrgTableRow = OrgContentRow (F [Blocks])
                 | OrgAlignRow [ColumnProperty]
                 | OrgHlineRow

-- OrgTable is strongly related to the pandoc table ADT.  Using the same
-- (i.e. pandoc-global) ADT would mean that the reader would break if the
-- global structure was to be changed, which would be bad.  The final table
-- should be generated using a builder function.
data OrgTable = OrgTable
  { orgTableColumnProperties :: [ColumnProperty]
  , orgTableHeader           :: [Blocks]
  , orgTableRows             :: [[Blocks]]
  }

table :: PandocMonad m => OrgParser m (F Blocks)
table = try $ do
  -- don't allow a table on the first line of a list item; org requires that
  -- tables start at first non-space character on the line
  let isFirstInListItem st = (orgStateParserContext st == ListItemState) &&
                             (orgStateLastPreCharPos st == Nothing)
  guard =<< not . isFirstInListItem <$> getState
  blockAttrs <- blockAttributes
  lookAhead tableStart
  do
    rows <- tableRows
    let caption = fromMaybe (return mempty) $ blockAttrCaption blockAttrs
    return $ (<$> caption) . orgToPandocTable . normalizeTable =<< rowsToTable rows

orgToPandocTable :: OrgTable
                 -> Inlines
                 -> Blocks
orgToPandocTable (OrgTable colProps heads lns) caption =
  let totalWidth = if any (not . isNothing) (map columnRelWidth colProps)
                   then Just . sum $ map (fromMaybe 1 . columnRelWidth) colProps
                   else Nothing
  in B.table caption (map (convertColProp totalWidth) colProps) heads lns
 where
   convertColProp :: Maybe Int -> ColumnProperty -> (Alignment, Double)
   convertColProp totalWidth colProp =
     let
       align' = fromMaybe AlignDefault $ columnAlignment colProp
       width' = fromMaybe 0 $ (\w t -> (fromIntegral w / fromIntegral t))
                              <$> (columnRelWidth colProp)
                              <*> totalWidth
     in (align', width')

tableRows :: PandocMonad m => OrgParser m [OrgTableRow]
tableRows = try $ many (tableAlignRow <|> tableHline <|> tableContentRow)

tableContentRow :: PandocMonad m => OrgParser m OrgTableRow
tableContentRow = try $
  OrgContentRow . sequence <$> (tableStart *> many1Till tableContentCell newline)

tableContentCell :: PandocMonad m => OrgParser m (F Blocks)
tableContentCell = try $
  fmap B.plain . trimInlinesF . mconcat <$> manyTill inline endOfCell

tableAlignRow :: Monad m => OrgParser m OrgTableRow
tableAlignRow = try $ do
  tableStart
  colProps <- many1Till columnPropertyCell newline
  -- Empty rows are regular (i.e. content) rows, not alignment rows.
  guard $ any (/= def) colProps
  return $ OrgAlignRow colProps

columnPropertyCell :: Monad m => OrgParser m ColumnProperty
columnPropertyCell = emptyCell <|> propCell <?> "alignment info"
 where
   emptyCell = ColumnProperty Nothing Nothing <$ (try $ skipSpaces *> endOfCell)
   propCell = try $ ColumnProperty
                 <$> (skipSpaces
                      *> char '<'
                      *> optionMaybe tableAlignFromChar)
                 <*> (optionMaybe (many1 digit >>= safeRead)
                      <* char '>'
                      <* emptyCell)

tableAlignFromChar :: Monad m => OrgParser m Alignment
tableAlignFromChar = try $
  choice [ char 'l' *> return AlignLeft
         , char 'c' *> return AlignCenter
         , char 'r' *> return AlignRight
         ]

tableHline :: Monad m => OrgParser m OrgTableRow
tableHline = try $
  OrgHlineRow <$ (tableStart *> char '-' *> anyLine)

endOfCell :: Monad m => OrgParser m Char
endOfCell = try $ char '|' <|> lookAhead newline

rowsToTable :: [OrgTableRow]
            -> F OrgTable
rowsToTable = foldM rowToContent emptyTable
 where emptyTable = OrgTable mempty mempty mempty

normalizeTable :: OrgTable -> OrgTable
normalizeTable (OrgTable colProps heads rows) =
  OrgTable colProps' heads rows
 where
   refRow = if heads /= mempty
            then heads
            else case rows of
                   (r:_) -> r
                   _     -> mempty
   cols = length refRow
   fillColumns base padding = take cols $ base ++ repeat padding
   colProps' = fillColumns colProps def

-- One or more horizontal rules after the first content line mark the previous
-- line as a header.  All other horizontal lines are discarded.
rowToContent :: OrgTable
             -> OrgTableRow
             -> F OrgTable
rowToContent orgTable row =
  case row of
    OrgHlineRow       -> return singleRowPromotedToHeader
    OrgAlignRow props -> return . setProperties $ props
    OrgContentRow cs  -> appendToBody cs
 where
   singleRowPromotedToHeader :: OrgTable
   singleRowPromotedToHeader = case orgTable of
     OrgTable{ orgTableHeader = [], orgTableRows = b:[] } ->
            orgTable{ orgTableHeader = b , orgTableRows = [] }
     _   -> orgTable

   setProperties :: [ColumnProperty] -> OrgTable
   setProperties ps = orgTable{ orgTableColumnProperties = ps }

   appendToBody :: F [Blocks] -> F OrgTable
   appendToBody frow = do
     newRow <- frow
     let oldRows = orgTableRows orgTable
     -- NOTE: This is an inefficient O(n) operation.  This should be changed
     -- if performance ever becomes a problem.
     return orgTable{ orgTableRows = oldRows ++ [newRow] }


--
-- LaTeX fragments
--
latexFragment :: Monad m => OrgParser m (F Blocks)
latexFragment = try $ do
  envName <- latexEnvStart
  content <- mconcat <$> manyTill anyLineNewline (latexEnd envName)
  return . return $ B.rawBlock "latex" (content `inLatexEnv` envName)
 where
   c `inLatexEnv` e = mconcat [ "\\begin{", e, "}\n"
                              , c
                              , "\\end{", e, "}\n"
                              ]

latexEnd :: Monad m => String -> OrgParser m ()
latexEnd envName = try $
  () <$ skipSpaces
     <* string ("\\end{" ++ envName ++ "}")
     <* blankline


--
-- Footnote defintions
--
noteBlock :: PandocMonad m => OrgParser m (F Blocks)
noteBlock = try $ do
  ref <- noteMarker <* skipSpaces <* updateLastPreCharPos
  content <- mconcat <$> blocksTillHeaderOrNote
  addToNotesTable (ref, content)
  return mempty
 where
   blocksTillHeaderOrNote =
     many1Till block (eof <|> () <$ lookAhead noteMarker
                          <|> () <$ lookAhead headerStart)

-- Paragraphs or Plain text
paraOrPlain :: PandocMonad m => OrgParser m (F Blocks)
paraOrPlain = try $ do
  -- Make sure we are not looking at a headline
  notFollowedBy' (char '*' *> (oneOf " *"))
  ils <- inlines
  nl <- option False (newline *> return True)
  -- Read block as paragraph, except if we are in a list context and the block
  -- is directly followed by a list item, in which case the block is read as
  -- plain text.
  try (guard nl
       *> notFollowedBy (inList *> (() <$ orderedListStart <|> bulletListStart))
       *> return (B.para <$> ils))
    <|>  (return (B.plain <$> ils))


--
-- list blocks
--

list :: PandocMonad m => OrgParser m (F Blocks)
list = choice [ definitionList, bulletList, orderedList ] <?> "list"

definitionList :: PandocMonad m => OrgParser m (F Blocks)
definitionList = try $ do n <- lookAhead (bulletListStart' Nothing)
                          fmap B.definitionList . fmap compactifyDL . sequence
                            <$> many1 (definitionListItem $ bulletListStart' (Just n))

bulletList :: PandocMonad m => OrgParser m (F Blocks)
bulletList = try $ do n <- lookAhead (bulletListStart' Nothing)
                      fmap B.bulletList . fmap compactify . sequence
                        <$> many1 (listItem (bulletListStart' $ Just n))

orderedList :: PandocMonad m => OrgParser m (F Blocks)
orderedList = fmap B.orderedList . fmap compactify . sequence
              <$> many1 (listItem orderedListStart)

bulletListStart' :: Monad m => Maybe Int -> OrgParser m Int
-- returns length of bulletList prefix, inclusive of marker
bulletListStart' Nothing  = do ind <- length <$> many spaceChar
                               oneOf (bullets $ ind == 0)
                               skipSpaces1
                               return (ind + 1)
bulletListStart' (Just n) = do count (n-1) spaceChar
                               oneOf (bullets $ n == 1)
                               many1 spaceChar
                               return n

-- Unindented lists are legal, but they can't use '*' bullets.
-- We return n to maintain compatibility with the generic listItem.
bullets :: Bool -> String
bullets unindented = if unindented then "+-" else "*+-"

definitionListItem :: PandocMonad m
                   => OrgParser m Int
                   -> OrgParser m (F (Inlines, [Blocks]))
definitionListItem parseMarkerGetLength = try $ do
  markerLength <- parseMarkerGetLength
  term <- manyTill (noneOf "\n\r") (try definitionMarker)
  line1 <- anyLineNewline
  blank <- option "" ("\n" <$ blankline)
  cont <- concat <$> many (listContinuation markerLength)
  term' <- parseFromString inlines term
  contents' <- parseFromString blocks $ line1 ++ blank ++ cont
  return $ (,) <$> term' <*> fmap (:[]) contents'
 where
   definitionMarker =
     spaceChar *> string "::" <* (spaceChar <|> lookAhead newline)


-- parse raw text for one list item, excluding start marker and continuations
listItem :: PandocMonad m
         => OrgParser m Int
         -> OrgParser m (F Blocks)
listItem start = try . withContext ListItemState $ do
  markerLength <- try start
  firstLine <- anyLineNewline
  blank <- option "" ("\n" <$ blankline)
  rest <- concat <$> many (listContinuation markerLength)
  parseFromString blocks $ firstLine ++ blank ++ rest

-- continuation of a list item - indented and separated by blankline or endline.
-- Note: nested lists are parsed as continuations.
listContinuation :: Monad m => Int
                 -> OrgParser m String
listContinuation markerLength = try $
  notFollowedBy' blankline
  *> (mappend <$> (concat <$> many1 listLine)
              <*> many blankline)
 where
   listLine = try $ indentWith markerLength *> anyLineNewline

   -- indent by specified number of spaces (or equiv. tabs)
   indentWith :: Monad m => Int -> OrgParser m String
   indentWith num = do
     tabStop <- getOption readerTabStop
     if num < tabStop
       then count num (char ' ')
       else choice [ try (count num (char ' '))
                   , try (char '\t' >> count (num - tabStop) (char ' ')) ]

-- | Parse any line, include the final newline in the output.
anyLineNewline :: Monad m => OrgParser m String
anyLineNewline = (++ "\n") <$> anyLine
