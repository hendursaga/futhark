{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Parser for the Futhark core language.
module Futhark.IR.Parse
  ( parseSOACS,
    parseKernels,
  )
where

import Data.Char
import Data.Functor
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Void
import Futhark.IR
import Futhark.IR.Kernels (Kernels)
import qualified Futhark.IR.Kernels.Kernel as Kernel
import Futhark.IR.SOACS (SOACS)
import qualified Futhark.IR.SOACS.SOAC as SOAC
import qualified Futhark.IR.SegOp as SegOp
import Futhark.Util.Pretty (prettyText)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type Parser = Parsec Void T.Text

pStringLiteral :: Parser String
pStringLiteral = char '"' >> manyTill L.charLiteral (char '"')

constituent :: Char -> Bool
constituent c = isAlphaNum c || (c `elem` ("_/'+-=!&^.<>*|" :: String))

whitespace :: Parser ()
whitespace = L.space space1 (L.skipLineComment "--") empty

lexeme :: Parser a -> Parser a
lexeme = try . L.lexeme whitespace

keyword :: T.Text -> Parser ()
keyword s = lexeme $ chunk s *> notFollowedBy (satisfy constituent)

pName :: Parser Name
pName =
  lexeme . fmap nameFromString $
    (:) <$> satisfy isAlpha <*> many (satisfy constituent)

pVName :: Parser VName
pVName = lexeme $ do
  (s, tag) <-
    satisfy constituent `manyTill_` try pTag
      <?> "variable name"
  pure $ VName (nameFromString s) tag
  where
    pTag =
      "_" *> L.decimal <* notFollowedBy (satisfy constituent)

pInt :: Parser Int
pInt = lexeme L.decimal

pInt64 :: Parser Int64
pInt64 = lexeme L.decimal

braces, brackets, parens :: Parser a -> Parser a
braces = between (lexeme "{") (lexeme "}")
brackets = between (lexeme "[") (lexeme "]")
parens = between (lexeme "(") (lexeme ")")

pComma, pColon, pSemi, pEqual, pSlash, pAsterisk :: Parser ()
pComma = void $ lexeme ","
pColon = void $ lexeme ":"
pSemi = void $ lexeme ";"
pEqual = void $ lexeme "="
pSlash = void $ lexeme "/"
pAsterisk = void $ lexeme "*"

pFloatType :: Parser FloatType
pFloatType = choice $ map p allFloatTypes
  where
    p t = keyword (prettyText t) $> t

pIntType :: Parser IntType
pIntType = choice $ map p allIntTypes
  where
    p t = keyword (prettyText t) $> t

pPrimType :: Parser PrimType
pPrimType =
  choice [p Bool, p Cert, FloatType <$> pFloatType, IntType <$> pIntType]
  where
    p t = keyword (prettyText t) $> t

pNonArray :: Parser (TypeBase shape u)
pNonArray = Prim <$> pPrimType

pTypeBase ::
  ArrayShape shape =>
  Parser shape ->
  Parser u ->
  Parser (TypeBase shape u)
pTypeBase ps pu = do
  u <- pu
  shape <- ps
  arrayOf <$> pNonArray <*> pure shape <*> pure u

pShape :: Parser Shape
pShape = Shape <$> many (brackets pSubExp)

pExtSize :: Parser ExtSize
pExtSize =
  choice
    [ lexeme $ "?" $> Ext <*> L.decimal,
      Free <$> pSubExp
    ]

pExtShape :: Parser ExtShape
pExtShape = Shape <$> many (brackets pExtSize)

pType :: Parser Type
pType = pTypeBase pShape (pure NoUniqueness)

pTypes :: Parser [Type]
pTypes = braces $ pType `sepBy` pComma

pExtType :: Parser ExtType
pExtType = pTypeBase pExtShape (pure NoUniqueness)

pDeclBase ::
  Parser (TypeBase shape NoUniqueness) ->
  Parser (TypeBase shape Uniqueness)
pDeclBase p =
  choice
    [ lexeme "*" $> (`toDecl` Unique) <*> p,
      (`toDecl` Nonunique) <$> p
    ]

pDeclType :: Parser DeclType
pDeclType = pDeclBase pType

pDeclExtType :: Parser DeclExtType
pDeclExtType = pDeclBase pExtType

pIntValue :: Parser IntValue
pIntValue = try $ do
  x <- L.signed (pure ()) L.decimal
  t <- pIntType
  pure $ intValue t (x :: Integer)

pFloatValue :: Parser FloatValue
pFloatValue =
  choice
    [ pNum,
      keyword "f32.nan" $> Float32Value (0 / 0),
      keyword "f32.inf" $> Float32Value (1 / 0),
      keyword "-f32.inf" $> Float32Value (-1 / 0),
      keyword "f64.nan" $> Float64Value (0 / 0),
      keyword "f64.inf" $> Float64Value (1 / 0),
      keyword "-f64.inf" $> Float64Value (-1 / 0)
    ]
  where
    pNum = try $ do
      x <- L.signed (pure ()) L.float
      t <- pFloatType
      pure $ floatValue t (x :: Double)

pBoolValue :: Parser Bool
pBoolValue =
  choice
    [ keyword "true" $> True,
      keyword "false" $> False
    ]

pPrimValue :: Parser PrimValue
pPrimValue =
  choice
    [ FloatValue <$> pFloatValue,
      IntValue <$> pIntValue,
      BoolValue <$> pBoolValue
    ]
    <?> "primitive value"

pSubExp :: Parser SubExp
pSubExp = Var <$> pVName <|> Constant <$> pPrimValue

pPatternLike :: Parser a -> Parser ([a], [a])
pPatternLike p = braces $ do
  xs <- p `sepBy` pComma
  choice
    [ pSemi *> ((xs,) <$> (p `sepBy` pComma)),
      pure (mempty, xs)
    ]

pConvOp ::
  T.Text -> (t1 -> t2 -> ConvOp) -> Parser t1 -> Parser t2 -> Parser BasicOp
pConvOp s op t1 t2 =
  keyword s $> op' <*> t1 <*> pSubExp <*> (keyword "to" *> t2)
  where
    op' f se t = ConvOp (op f t) se

pBinOp :: Parser BasicOp
pBinOp = choice (map p allBinOps) <?> "binary op"
  where
    p bop =
      keyword (prettyText bop)
        *> parens (BinOp bop <$> pSubExp <* pComma <*> pSubExp)

pCmpOp :: Parser BasicOp
pCmpOp = choice (map p allCmpOps) <?> "comparison op"
  where
    p op =
      keyword (prettyText op)
        *> parens (CmpOp op <$> pSubExp <* pComma <*> pSubExp)

pUnOp :: Parser BasicOp
pUnOp = choice (map p allUnOps) <?> "unary op"
  where
    p bop = keyword (prettyText bop) $> UnOp bop <*> pSubExp

pDimIndex :: Parser (DimIndex SubExp)
pDimIndex =
  choice
    [ try $
        DimSlice <$> pSubExp <* lexeme ":+"
          <*> pSubExp <* lexeme "*"
          <*> pSubExp,
      DimFix <$> pSubExp
    ]

pSlice :: Parser (Slice SubExp)
pSlice = brackets $ pDimIndex `sepBy` pComma

pIndex :: Parser BasicOp
pIndex = try $ Index <$> pVName <*> pSlice

pErrorMsgPart :: Parser (ErrorMsgPart SubExp)
pErrorMsgPart =
  choice
    [ ErrorString <$> pStringLiteral,
      flip ($) <$> (pSubExp <* pColon)
        <*> choice
          [ keyword "i32" $> ErrorInt32,
            keyword "i64" $> ErrorInt64
          ]
    ]

pErrorMsg :: Parser (ErrorMsg SubExp)
pErrorMsg = ErrorMsg <$> braces (pErrorMsgPart `sepBy` pComma)

pSrcLoc :: Parser SrcLoc
pSrcLoc = pStringLiteral $> mempty -- FIXME

pErrorLoc :: Parser (SrcLoc, [SrcLoc])
pErrorLoc = (,mempty) <$> pSrcLoc

pShapeChange :: Parser (ShapeChange SubExp)
pShapeChange = parens $ pDimChange `sepBy` pComma
  where
    pDimChange =
      choice
        [ "~" $> DimCoercion <*> pSubExp,
          DimNew <$> pSubExp
        ]

pIota :: Parser BasicOp
pIota =
  choice $ map p allIntTypes
  where
    p t =
      keyword ("iota" <> prettyText (primBitSize (IntType t)))
        *> parens
          ( Iota
              <$> pSubExp <* pComma
              <*> pSubExp <* pComma
              <*> pSubExp
              <*> pure t
          )

pBasicOp :: Parser BasicOp
pBasicOp =
  choice
    [ keyword "opaque" $> Opaque <*> parens pSubExp,
      keyword "copy" $> Copy <*> parens pVName,
      keyword "assert"
        *> parens
          ( Assert <$> pSubExp <* pComma
              <*> pErrorMsg <* pComma
              <*> pErrorLoc
          ),
      keyword "rotate"
        *> parens
          (Rotate <$> parens (pSubExp `sepBy` pComma) <* pComma <*> pVName),
      keyword "replicate"
        *> parens (Replicate <$> pShape <* pComma <*> pSubExp),
      keyword "reshape"
        *> parens (Reshape <$> pShapeChange <* pComma <*> pVName),
      keyword "scratch"
        *> parens (Scratch <$> pPrimType <*> many (pComma *> pSubExp)),
      keyword "rearrange"
        *> parens
          (Rearrange <$> parens (pInt `sepBy` pComma) <* pComma <*> pVName),
      keyword "manifest"
        *> parens
          (Manifest <$> parens (pInt `sepBy` pComma) <* pComma <*> pVName),
      keyword "concat" *> do
        d <- "@" *> L.decimal
        parens $ do
          w <- pSubExp <* pComma
          Concat d <$> pVName <*> many (pComma *> pVName) <*> pure w,
      pIota,
      try $
        Update
          <$> pVName <* keyword "with"
          <*> pSlice <* lexeme "="
          <*> pSubExp,
      ArrayLit
        <$> brackets (pSubExp `sepBy` pComma)
        <*> (lexeme ":" *> "[]" *> pType),
      --
      pConvOp "sext" SExt pIntType pIntType,
      pConvOp "zext" ZExt pIntType pIntType,
      pConvOp "fpconv" FPConv pFloatType pFloatType,
      pConvOp "fptoui" FPToUI pFloatType pIntType,
      pConvOp "fptosi" FPToSI pFloatType pIntType,
      pConvOp "uitofp" UIToFP pIntType pFloatType,
      pConvOp "sitofp" SIToFP pIntType pFloatType,
      pConvOp "itob" (const . IToB) pIntType (keyword "bool"),
      pConvOp "btoi" (const BToI) (keyword "bool") pIntType,
      --
      pIndex,
      pBinOp,
      pCmpOp,
      pUnOp,
      SubExp <$> pSubExp
    ]

pAttr :: Parser Attr
pAttr = do
  v <- pName
  choice
    [ AttrComp v <$> parens (pAttr `sepBy` pComma),
      pure $ AttrAtom v
    ]

pAttrs :: Parser Attrs
pAttrs = Attrs . S.fromList <$> many pAttr'
  where
    pAttr' = lexeme "#[" *> pAttr <* lexeme "]"

pComm :: Parser Commutativity
pComm =
  choice
    [ keyword "commutative" $> Commutative,
      pure Noncommutative
    ]

data PR lore = PR
  { pRetType :: Parser (RetType lore),
    pBranchType :: Parser (BranchType lore),
    pFParamInfo :: Parser (FParamInfo lore),
    pLParamInfo :: Parser (LParamInfo lore),
    pLetDec :: Parser (LetDec lore),
    pOp :: Parser (Op lore),
    pBodyDec :: BodyDec lore,
    pExpDec :: ExpDec lore
  }

pRetTypes :: PR lore -> Parser [RetType lore]
pRetTypes pr = braces $ pRetType pr `sepBy` pComma

pBranchTypes :: PR lore -> Parser [BranchType lore]
pBranchTypes pr = braces $ pBranchType pr `sepBy` pComma

pParam :: Parser t -> Parser (Param t)
pParam p = Param <$> pVName <*> (pColon *> p)

pFParam :: PR lore -> Parser (FParam lore)
pFParam = pParam . pFParamInfo

pFParams :: PR lore -> Parser [FParam lore]
pFParams pr = parens $ pFParam pr `sepBy` pComma

pLParam :: PR lore -> Parser (LParam lore)
pLParam = pParam . pLParamInfo

pLParams :: PR lore -> Parser [LParam lore]
pLParams pr = parens $ pLParam pr `sepBy` pComma

pPatElem :: PR lore -> Parser (PatElem lore)
pPatElem pr =
  (PatElem <$> pVName <*> (pColon *> pLetDec pr)) <?> "pattern element"

pPattern :: PR lore -> Parser (Pattern lore)
pPattern pr = uncurry Pattern <$> pPatternLike (pPatElem pr)

pIf :: PR lore -> Parser (Exp lore)
pIf pr =
  keyword "if" $> f <*> pSort <*> pSubExp
    <*> (keyword "then" *> pBranchBody)
    <*> (keyword "else" *> pBranchBody)
    <*> (lexeme ":" *> pBranchTypes pr)
  where
    pSort =
      choice
        [ lexeme "<fallback>" $> IfFallback,
          lexeme "<equiv>" $> IfEquiv,
          pure IfNormal
        ]
    f sort cond tbranch fbranch t =
      If cond tbranch fbranch $ IfDec t sort
    pBranchBody =
      choice
        [ try $ braces $ Body (pBodyDec pr) mempty <$> pSubExp `sepBy` pComma,
          braces (pBody pr)
        ]

pApply :: PR lore -> Parser (Exp lore)
pApply pr =
  keyword "apply"
    $> Apply
    <*> pName
    <*> parens (pArg `sepBy` pComma) <* pColon
    <*> pRetTypes pr
    <*> pure (Safe, mempty, mempty)
  where
    pArg =
      choice
        [ lexeme "*" $> (,Consume) <*> pSubExp,
          (,Observe) <$> pSubExp
        ]

pLoop :: PR lore -> Parser (Exp lore)
pLoop pr =
  keyword "loop" $> uncurry DoLoop
    <*> pLoopParams
    <*> pLoopForm <* keyword "do"
    <*> braces (pBody pr)
  where
    pLoopParams = do
      (ctx, val) <- pPatternLike (pFParam pr)
      void $ lexeme "="
      (ctx_init, val_init) <-
        splitAt (length ctx) <$> braces (pSubExp `sepBy` pComma)
      pure (zip ctx ctx_init, zip val val_init)

    pLoopForm =
      choice
        [ keyword "for" $> ForLoop
            <*> pVName <* lexeme ":"
            <*> pIntType <* lexeme "<"
            <*> pSubExp
            <*> many ((,) <$> pLParam pr <* keyword "in" <*> pVName),
          keyword "while" $> WhileLoop <*> pVName
        ]

pLambda :: PR lore -> Parser (Lambda lore)
pLambda pr =
  choice
    [ keyword "fn"
        $> lam
        <*> pTypes
        <*> pLParams pr <* lexeme "=>"
        <*> pBody pr,
      keyword "nilFn" $> Lambda mempty (Body (pBodyDec pr) mempty []) []
    ]
  where
    lam ret params body = Lambda params body ret

pReduce :: PR lore -> Parser (SOAC.Reduce lore)
pReduce pr =
  SOAC.Reduce
    <$> pComm
    <*> pLambda pr <* pComma
    <*> braces (pSubExp `sepBy` pComma)

pScan :: PR lore -> Parser (SOAC.Scan lore)
pScan pr =
  SOAC.Scan
    <$> pLambda pr <* pComma
    <*> braces (pSubExp `sepBy` pComma)

pExp :: PR lore -> Parser (Exp lore)
pExp pr =
  choice
    [ pIf pr,
      pApply pr,
      pLoop pr,
      Op <$> pOp pr,
      BasicOp <$> pBasicOp
    ]

pStm :: PR lore -> Parser (Stm lore)
pStm pr =
  keyword "let" $> Let <*> pPattern pr <* pEqual <*> pStmAux <*> pExp pr
  where
    pStmAux = flip StmAux <$> pAttrs <*> pCerts <*> pure (pExpDec pr)
    pCerts =
      choice
        [ lexeme "#" *> braces (Certificates <$> pVName `sepBy` pComma)
            <?> "certificates",
          pure mempty
        ]

pStms :: PR lore -> Parser (Stms lore)
pStms pr = stmsFromList <$> many (pStm pr)

pBody :: PR lore -> Parser (Body lore)
pBody pr =
  choice
    [ Body (pBodyDec pr) <$> pStms pr <* keyword "in" <*> pResult,
      Body (pBodyDec pr) mempty <$> pResult
    ]
  where
    pResult = braces $ pSubExp `sepBy` pComma

pFunDef :: PR lore -> Parser (FunDef lore)
pFunDef pr = do
  attrs <- pAttrs
  entry <- (keyword "entry" <|> keyword "fun") $> Nothing
  ret <- pRetTypes pr
  FunDef entry attrs
    <$> pName
    <*> pure ret
    <*> pFParams pr
    <*> (pEqual *> braces (pBody pr))

pProg :: PR lore -> Parser (Prog lore)
pProg pr = Prog <$> pStms pr <*> many (pFunDef pr)

pSOAC :: PR lore -> Parser (SOAC.SOAC lore)
pSOAC pr =
  choice
    [ keyword "map" *> pScrema pMapForm,
      keyword "redomap" *> pScrema pRedomapForm,
      keyword "scanomap" *> pScrema pScanomapForm,
      keyword "screma" *> pScrema pScremaForm,
      pScatter,
      pHist,
      pStream
    ]
  where
    pScrema p =
      parens $
        SOAC.Screma
          <$> pSubExp <* pComma
          <*> p <* pComma
          <*> (pVName `sepBy` pComma)
    pScremaForm =
      SOAC.ScremaForm
        <$> braces (pScan pr `sepBy` pComma) <* pComma
        <*> braces (pReduce pr `sepBy` pComma) <* pComma
        <*> pLambda pr
    pRedomapForm =
      SOAC.ScremaForm mempty
        <$> braces (pReduce pr `sepBy` pComma) <* pComma
        <*> pLambda pr
    pScanomapForm =
      SOAC.ScremaForm
        <$> braces (pScan pr `sepBy` pComma) <* pComma
        <*> pure mempty
        <*> pLambda pr
    pMapForm =
      SOAC.ScremaForm mempty mempty <$> pLambda pr
    pScatter =
      keyword "scatter"
        *> parens
          ( SOAC.Scatter <$> pSubExp <* pComma
              <*> pLambda pr <* pComma
              <*> braces (pVName `sepBy` pComma)
              <*> many (pComma *> pDest)
          )
      where
        pDest =
          parens $ (,,) <$> pShape <* pComma <*> pInt <* pComma <*> pVName
    pHist =
      keyword "hist"
        *> parens
          ( SOAC.Hist
              <$> pSubExp <* pComma
              <*> braces (pHistOp `sepBy` pComma) <* pComma
              <*> pLambda pr
              <*> many (pComma *> pVName)
          )
      where
        pHistOp =
          SOAC.HistOp
            <$> pSubExp <* pComma
            <*> pSubExp <* pComma
            <*> braces (pVName `sepBy` pComma) <* pComma
            <*> braces (pSubExp `sepBy` pComma) <* pComma
            <*> pLambda pr
    pStream =
      choice
        [ keyword "streamParComm" *> pStreamPar SOAC.InOrder Commutative,
          keyword "streamPar" *> pStreamPar SOAC.InOrder Noncommutative,
          keyword "streamParPerComm" *> pStreamPar SOAC.Disorder Commutative,
          keyword "streamParPer" *> pStreamPar SOAC.Disorder Noncommutative,
          keyword "streamSeq" *> pStreamSeq
        ]
    pStreamPar order comm =
      parens $
        SOAC.Stream
          <$> pSubExp <* pComma
          <*> pParForm order comm <* pComma
          <*> pLambda pr <* pComma
          <*> braces (pSubExp `sepBy` pComma)
          <*> many (pComma *> pVName)
    pParForm order comm =
      SOAC.Parallel order comm <$> pLambda pr
    pStreamSeq =
      parens $
        SOAC.Stream
          <$> pSubExp <* pComma
          <*> pure SOAC.Sequential
          <*> pLambda pr <* pComma
          <*> braces (pSubExp `sepBy` pComma)
          <*> many (pComma *> pVName)

pSizeClass :: Parser Kernel.SizeClass
pSizeClass =
  choice
    [ keyword "group_size" $> Kernel.SizeGroup,
      keyword "num_groups" $> Kernel.SizeNumGroups,
      keyword "num_groups" $> Kernel.SizeNumGroups,
      keyword "tile_size" $> Kernel.SizeTile,
      keyword "reg_tile_size" $> Kernel.SizeRegTile,
      keyword "local_memory" $> Kernel.SizeLocalMemory,
      keyword "threshold"
        *> parens
          ( Kernel.SizeThreshold
              <$> pKernelPath
              <*> optional (pComma *> pInt64)
          ),
      keyword "bespoke"
        *> parens (Kernel.SizeBespoke <$> pName <* pComma <*> pInt64)
    ]
  where
    pKernelPath =
      brackets $ pStep `sepBy` pComma
    pStep =
      choice
        [ lexeme "!" $> (,) <*> pName <*> pure False,
          (,) <$> pName <*> pure True
        ]

pSizeOp :: Parser Kernel.SizeOp
pSizeOp =
  choice
    [ keyword "get_size"
        *> parens (Kernel.GetSize <$> pName <* pComma <*> pSizeClass),
      keyword "get_size_max"
        *> parens (Kernel.GetSizeMax <$> pSizeClass),
      keyword "cmp_size"
        *> ( parens (Kernel.CmpSizeLe <$> pName <* pComma <*> pSizeClass)
               <*> (lexeme "<=" *> pSubExp)
           ),
      keyword "calc_num_groups"
        *> parens
          ( Kernel.CalcNumGroups
              <$> pSubExp <* pComma <*> pName <* pComma <*> pSubExp
          ),
      keyword "split_space"
        *> parens
          ( Kernel.SplitSpace Kernel.SplitContiguous
              <$> pSubExp <* pComma
              <*> pSubExp <* pComma
              <*> pSubExp
          ),
      keyword "split_space_strided"
        *> parens
          ( Kernel.SplitSpace
              <$> (Kernel.SplitStrided <$> pSubExp) <* pComma
              <*> pSubExp <* pComma
              <*> pSubExp <* pComma
              <*> pSubExp
          )
    ]

pSegSpace :: Parser SegOp.SegSpace
pSegSpace =
  flip SegOp.SegSpace
    <$> parens (pDim `sepBy` pComma)
    <*> parens (lexeme "~" *> pVName)
  where
    pDim = (,) <$> pVName <* lexeme "<" <*> pSubExp

pKernelResult :: Parser SegOp.KernelResult
pKernelResult =
  choice
    [ keyword "returns" $> SegOp.Returns
        <*> choice
          [ keyword "(manifest)" $> SegOp.ResultNoSimplify,
            keyword "(private)" $> SegOp.ResultPrivate,
            pure SegOp.ResultMaySimplify
          ]
        <*> pSubExp,
      try $
        flip SegOp.WriteReturns
          <$> pVName <* pColon
          <*> pShape <* keyword "with"
          <*> parens (pWrite `sepBy` pComma),
      try "tile"
        *> parens (SegOp.TileReturns <$> (pTile `sepBy` pComma)) <*> pVName,
      try "blkreg_tile"
        *> parens (SegOp.RegTileReturns <$> (pRegTile `sepBy` pComma)) <*> pVName,
      keyword "concat"
        *> parens
          ( SegOp.ConcatReturns SegOp.SplitContiguous
              <$> pSubExp <* pComma
              <*> pSubExp
          )
        <*> pVName,
      keyword "concat_strided"
        *> parens
          ( SegOp.ConcatReturns
              <$> (SegOp.SplitStrided <$> pSubExp) <* pComma
              <*> pSubExp <* pComma
              <*> pSubExp
          )
        <*> pVName
    ]
  where
    pTile = (,) <$> pSubExp <* pSlash <*> pSubExp
    pRegTile = do
      dim <- pSubExp <* pSlash
      parens $ do
        blk_tile <- pSubExp <* pAsterisk
        reg_tile <- pSubExp
        pure (dim, blk_tile, reg_tile)
    pWrite = (,) <$> pSlice <* pEqual <*> pSubExp

pKernelBody :: PR lore -> Parser (SegOp.KernelBody lore)
pKernelBody pr =
  SegOp.KernelBody (pBodyDec pr)
    <$> pStms pr <* keyword "return"
    <*> braces (pKernelResult `sepBy` pComma)

pSegOp :: PR lore -> Parser lvl -> Parser (SegOp.SegOp lvl lore)
pSegOp pr pLvl =
  choice
    [ keyword "segmap" *> pSegMap,
      keyword "segred" *> pSegRed,
      keyword "segscan" *> pSegScan,
      keyword "seghist" *> pSegHist
    ]
  where
    pSegMap =
      SegOp.SegMap
        <$> pLvl
        <*> pSegSpace <* pColon
        <*> pTypes
        <*> braces (pKernelBody pr)
    pSegOp' f p =
      f <$> pLvl
        <*> pSegSpace
        <*> parens (p `sepBy` pComma) <* pColon
        <*> pTypes
        <*> braces (pKernelBody pr)
    pSegBinOp = do
      nes <- braces (pSubExp `sepBy` pComma) <* pComma
      shape <- pShape <* pComma
      comm <- pComm
      lam <- pLambda pr
      pure $ SegOp.SegBinOp comm lam nes shape
    pHistOp =
      SegOp.HistOp
        <$> pSubExp <* pComma
        <*> pSubExp <* pComma
        <*> braces (pVName `sepBy` pComma) <* pComma
        <*> braces (pSubExp `sepBy` pComma) <* pComma
        <*> pShape <* pComma
        <*> pLambda pr
    pSegRed = pSegOp' SegOp.SegRed pSegBinOp
    pSegScan = pSegOp' SegOp.SegScan pSegBinOp
    pSegHist = pSegOp' SegOp.SegHist pHistOp

pSegLevel :: Parser Kernel.SegLevel
pSegLevel =
  parens $
    choice
      [ keyword "thread" $> Kernel.SegThread,
        keyword "group" $> Kernel.SegGroup
      ]
      <*> (pSemi *> lexeme "#groups=" $> Kernel.Count <*> pSubExp)
      <*> (pSemi *> lexeme "groupsize=" $> Kernel.Count <*> pSubExp)
      <*> choice
        [ pSemi
            *> choice
              [ keyword "full" $> SegOp.SegNoVirtFull,
                keyword "virtualise" $> SegOp.SegVirt
              ],
          pure SegOp.SegNoVirt
        ]

pHostOp :: PR lore -> Parser op -> Parser (Kernel.HostOp lore op)
pHostOp pr pOther =
  choice
    [ Kernel.SegOp <$> pSegOp pr pSegLevel,
      Kernel.SizeOp <$> pSizeOp,
      Kernel.OtherOp <$> pOther
    ]

prSOACS :: PR SOACS
prSOACS = PR pDeclExtType pExtType pDeclType pType pType (pSOAC prSOACS) () ()

prKernels :: PR Kernels
prKernels = PR pDeclExtType pExtType pDeclType pType pType op () ()
  where
    op = pHostOp prKernels (pSOAC prKernels)

parseLore :: PR lore -> FilePath -> T.Text -> Either T.Text (Prog lore)
parseLore pr fname s =
  either (Left . T.pack . errorBundlePretty) Right $
    parse (whitespace *> pProg pr <* eof) fname s

parseSOACS :: FilePath -> T.Text -> Either T.Text (Prog SOACS)
parseSOACS = parseLore prSOACS

parseKernels :: FilePath -> T.Text -> Either T.Text (Prog Kernels)
parseKernels = parseLore prKernels
