{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies, FlexibleInstances #-}
module Language.C.Obfuscate.CPS
       where
import Data.Char
import qualified Data.Map as M
import qualified Language.C.Syntax.AST as AST
import qualified Language.C.Data.Node as N 
import Language.C.Syntax.Constants
import Language.C.Data.Ident

import Language.C.Obfuscate.Var
import Language.C.Obfuscate.CFG 
import Language.C.Obfuscate.SSA


-- import for testing
import Language.C (parseCFile, parseCFilePre)
import Language.C.System.GCC (newGCC)
import Language.C.Pretty (pretty)
import Text.PrettyPrint.HughesPJ (render, text, (<+>), hsep)

{- Source Language SSA

(Prog)  p ::= t x (\bar{t x}) {\bar{d}; \bar{b} }

(Decl)  d ::= t x

(Block) b ::= l: {s} | l: {\bar{i} ; s} 

(Stmts) s ::= x = e; s | goto l; | return e; | e; s | if e { s } else { s } 

(Phi)   i ::= x = \phi(\bar{g})

(Exp)   e ::= v | e (\bar{e})

(Labelled argument) g ::= (l:e)

(Label) l ::= l0 | ... | ln

(Value) v ::= x | c

(Type)  t ::= int | bool | t* | t[] | | void

(Loop environment) \Delta ::= (l_if, e_cond, l_true, l_false)
-}

-- was imported from SSA

{- Target Language CPS
(Prog)  P ::= T X (\bar{T X}) {\bar{D}; \bar{B} }

(Block) B ::= S

(Decl)  D ::= T X | P /* nested functions */

(Stmts)  S ::= X = E ; S | return E; | E; S |  if E { S } else { S } 

(Exp) E ::=  V | E(\bar{E})

(Value) V :: = X | C | (\bar{T X}):T => {\bar{D}; \bar{B}}

(Variable) X ::= x | y | k | ...

(Type) T :: = int | bool | T * | T => T | T[] | void
-}

-- ^ a CPS function declaration AST
data CPS = CPS { cps_decls :: [AST.CDeclaration N.NodeInfo]  -- ^ main function decls
               , cps_stmts :: [AST.CCompoundBlockItem N.NodeInfo]  -- ^ main function stmts
               , cps_funcs :: [AST.CFunctionDef N.NodeInfo] -- ^ generated auxillary functions
               , cps_ctxt  :: AST.CDeclaration N.NodeInfo -- ^ the context for the closure
               } deriving Show
                          
                          
                          
{-
class CPSize ssa cps where
  cps_trans :: ssa -> cps 
  
instance CPSize a b => CPSize [a] [b] where
  cps_trans as = map cps_trans as
  
  
instance CPSize (Ident, LabeledBlock) (AST.CFunctionDef N.NodeInfo) where  
  cps_trans (label, lb) = undefined
  
  
  
{-  
translation     d => D
t => T     x => X
----------------------
t x => T X
-}
instance CPSize (AST.CDeclaration N.NodeInfo) (AST.CDeclaration N.NodeInfo) where
  cps_trans decl = case decl of 
    { AST.CDecl tyspec tripls nodeInfo -> 
         let tyspec' = cps_trans tyspec
             tripls' = map (\(mb_decltr, mb_init, mb_size) -> 
                             let mb_decltr' = case mb_decltr of 
                                   { Nothing     -> Nothing 
                                   ; Just decltr -> Just decltr -- todo
                                   }
                                 mb_init' = case mb_init of 
                                   { Nothing     -> Nothing
                                   ; Just init   -> Just init   -- todo
                                   }
                                 mb_size' = case mb_size of
                                   { Nothing     -> Nothing
                                   ; Just size   -> Just size   -- todo
                                   }
                             in (mb_decltr', mb_init', mb_size')                
                             ) tripls
         in  AST.CDecl tyspec' tripls' nodeInfo
    -- ; AST.CStaticAssert e lit nodeInfo -> undefined
    }
    
{- 
translation  t => T

-----------
int => int

-----------
bool => bool

t => t
-------------
t* => T*

t => T
------------
t[] => T[]


-------------
void => void
-}
                   
instance CPSize (AST.CDeclarationSpecifier N.NodeInfo) (AST.CDeclarationSpecifier N.NodeInfo) where
  cps_trans tyspec = tyspec -- todo: unroll it
{-
data CDeclarationSpecifier a
  = CStorageSpec (CStorageSpecifier a) -- ^ storage-class specifier or typedef
  | CTypeSpec    (CTypeSpecifier a)    -- ^ type name
  | CTypeQual    (CTypeQualifier a)    -- ^ type qualifier
  | CFunSpec     (CFunctionSpecifier a) -- ^ function specifier
  | CAlignSpec   (CAlignmentSpecifier a) -- ^ alignment specifier
    deriving (Show, Data,Typeable {-! ,CNode ,Functor, Annotated !-})
-}
  
  
{-  
---------
x => X
-}

instance CPSize (AST.CDeclarator N.NodeInfo) (AST.CDeclarator N.NodeInfo) where
  cps_trans declr@(AST.CDeclr mb_ident derivedDecltrs mb_cstrLtr attrs nodeInfo) = declr 

-}


{- fn, K, \bar{\Delta} |- \bar{b} => \bar{P}
translating the labeled blocks to function decls


fn, K, \bar{\Delta}, \bar{b}  |- b_i => P_i
-----------------------------------
fn, K, \bar{\Delta} |- \bar{b} => \bar{P}
-}

cps_trans_lbs :: Ident ->  -- ^ top level function name
                 Ident -> -- ^ K, the continuation
                 -- ^ \bar{\Delta} become part of the labelled block flag (loop) 
                 M.Map Ident LabeledBlock ->  -- ^ \bar{b}
                 [AST.CFunctionDef N.NodeInfo] 
cps_trans_lbs fname k lb_map = map (\(id,lb) -> cps_trans_lb fname k lb_map id lb) (M.toList lb_map)

{- fn, K, \bar{\Delta}, \bar{b}  |- b => P -}


cps_trans_lb :: Ident ->  -- ^ top level function name
                Ident -> -- ^ K
                -- ^ \bar{\Delta} become part of the labelled block flag (loop) 
                M.Map Ident LabeledBlock ->  -- ^ \bar{b}
                Ident ->  -- ^ label for the current block
                LabeledBlock ->  -- ^ the block
                AST.CFunctionDef N.NodeInfo

{-
fn, K, \bar{\Delta}, \bar{b} |- s => S
----------------------------------------------------------------- (LabBlk)
fn, K, \bar{\Delta}, \bar{b}  |- l_i : {s} => void fn_i() { S } 

fn, K, \bar{\Delta}, \bar{b} |- s => S
--------------------------------------------------------------------------- (PhiBlk)
fn, K, \bar{\Delta}, \bar{b}  |- l_i : {\bar{i}; s} => void fn_i() { S }

-}


cps_trans_lb  fname k lb_map ident lb = 
  let stmt' =  AST.CCompound [] (cps_trans_stmts fname k lb_map ident (lb_stmts lb)) N.undefNode
      fname' = fname `app` ident
      tyVoid = [AST.CTypeSpec (AST.CVoidType N.undefNode)]
      declrs = []
      decltrs = []
      mb_strLitr = Nothing
      attrs  =  []
  in AST.CFunDef tyVoid (AST.CDeclr (Just fname') decltrs mb_strLitr attrs N.undefNode) declrs stmt' N.undefNode
    
     
     
cps_trans_stmts :: Ident -> -- ^ fname 
                   Ident -> -- ^ K
                   -- ^ \bar{\Delta} become part of the labelled block flag (loop) 
                   M.Map Ident LabeledBlock ->  -- ^ \bar{b}
                   Ident ->  -- ^ label for the current block
                   [AST.CCompoundBlockItem N.NodeInfo] ->  -- ^ stmts
                   [AST.CCompoundBlockItem N.NodeInfo]
cps_trans_stmts fname k lb_map ident stmts = concatMap (\stmt -> cps_trans_stmt fname k lb_map ident stmt) stmts


-- fn, K, \bar{\Delta}, \bar{b} |-_l s => S
cps_trans_stmt :: Ident -> Ident ->  M.Map Ident LabeledBlock -> Ident -> AST.CCompoundBlockItem N.NodeInfo -> [AST.CCompoundBlockItem N.NodeInfo]
{-
l_i : { \bar{i} ; s } \in \bar{b}   l |- \bar{i} => x1 = e1; ...; xn =en; 
----------------------------------------------------------------------------- (GT1)
fn, K, \bar{\Delta}, \bar{b} |-_l goto l_i => x1 = e1; ...; xn = en ; fnl_{i}(k)
-}
cps_trans_stmt fname k lb_map ident (AST.CBlockStmt (AST.CGoto li nodeInfo)) = case M.lookup li lb_map of 
  { Just lb | null (phis lb) -> let as = cps_trans_phis ident (phis lb)
                                    fname' = fname `app` li
                                    funcall = AST.CBlockStmt (AST.CExpr (Just (AST.CCall (AST.CVar fname' N.undefNode) [(AST.CVar k N.undefNode)] N.undefNode)) N.undefNode)
                                in as ++ [ funcall ]
{-
l_i : { s } \in \bar{b}    
----------------------------------------------------------------------------- (GT2)
fn, K, \bar{\Delta}, \bar{b} |-_l goto l_i => fnl_{i}(k)
-}                                   
            | otherwise      -> let fname' = fname `app` li
                                    funcall = AST.CBlockStmt (AST.CExpr (Just (AST.CCall (AST.CVar fname' N.undefNode) [(AST.CVar k N.undefNode)] N.undefNode)) N.undefNode)
                                in [ funcall ]
  ; Nothing -> error "cps_trans_stmt failed at a non existent label."
  }

cps_trans_stmt fname k lb_map ident stmt = undefined
     


cps_trans_phis ::  Ident -- ^ caller's label
                   -> [( Ident -- ^ var being redefined 
                       , [(Ident, Ident)])] -- ^ incoming block x renamed variables
                   ->  [AST.CCompoundBlockItem N.NodeInfo]
cps_trans_phis caller_lb ps = map (cps_trans_phi caller_lb) ps


cps_trans_phi :: Ident -> (Ident, [(Ident, Ident)]) -> AST.CCompoundBlockItem N.NodeInfo
cps_trans_phi caller_lb (var, pairs) = 
  case lookup caller_lb pairs of 
    { Nothing -> error "cps_trans_phi failed: can't find the caller label from the incoming block."
    ; Just renamedVar -> AST.CBlockStmt (AST.CExpr (Just (AST.CAssign AST.CAssignOp (AST.CVar var N.undefNode) (AST.CVar renamedVar N.undefNode) N.undefNode)) N.undefNode) -- todo check var has been renamed with context
    }


{-
top level translation   p => P

t => T    x => X     ti => Ti     xi => Xi     di => Di
\bar{b} |- \bar{\Delta}    id, \bar{\Delta} |- \bar{b} => \bar{P}
P1 = void f1 (void => void k) { B1 } 
-------------------------------------------------------------------------
|- t x (\bar{t x}) {\bar{d};\bar{b}}  => 
         T X (\bar{T X}) {\bar{D}; T rx; \bar{P}; f1(id); return rx; }
-}
-- our target language C differs from the above specification.                          
-- 1. the top function's type signature is not captured within SSA
-- 2. \Delta is captured as the loop flag in LabaledBlock
-- 3. there is no lambda expression, closure needs to be created as a context
ssa2cps :: (AST.CFunctionDef N.NodeInfo) -> SSA -> CPS 
ssa2cps fundef (SSA scopedDecls labelledBlocks) = 
  let funName = case getFunName fundef of { Just s -> s ; Nothing -> "unanmed" }
      context = mkContext (funName ++ "Ctxt") scopedDecls
      
  in undefined

getFunName :: (AST.CFunctionDef N.NodeInfo) -> Maybe String
getFunName (AST.CFunDef tySpecfs declarator decls stmt nodeInfo) = getDeclrName declarator

getDeclrName :: (AST.CDeclarator N.NodeInfo) -> Maybe String
getDeclrName (AST.CDeclr Nothing decltrs mb_strLtr attrs nodeInfo) = Nothing
getDeclrName (AST.CDeclr (Just (Ident str _ _)) decltrs mb_strLtr attrs nodeInfo)  = Just str


mkContext :: String -> [AST.CDeclaration N.NodeInfo] -> AST.CDeclaration N.NodeInfo
mkContext name decls = 
  let structName  = internalIdent name
      ctxtAlias = AST.CDeclr (Just (internalIdent (map toLower name))) [] Nothing [] N.undefNode
      attrs     = []
      decls'    = decls
      tyDef     = AST.CStorageSpec (AST.CTypedef N.undefNode)
      structDef =
        AST.CTypeSpec (AST.CSUType
                       (AST.CStruct AST.CStructTag (Just structName) (Just decls') attrs N.undefNode) N.undefNode) 
  in AST.CDecl [tyDef, structDef] [(Just ctxtAlias, Nothing, Nothing)] N.undefNode


{-

typedef struct FibCtxt {
  int x_0;
  int (*cond2)(struct FibCtxt *);
  void (*visitor3)(void (*k)(struct FibCtxt*), struct FibCtxt*);
} fibctxt;



CTranslUnit 
  [CDeclExt (CDecl  -- type specifier
             [ CStorageSpec (CTypedef (NodeInfo ("test.c": line 3) (("test.c": line 3),7) (Name {nameId = 0}))) -- typedef
             , CTypeSpec (CSUType {- struct or union type -} (CStruct  -- typename struct
                                   CStructTag  -- to indicate that itis a struct not a union but should not CStruct do the job?
                                   (Just (Ident "FibCtxt" 144044346 (NodeInfo ("test.c": line 3) (("test.c": line 3),7) (Name {nameId = 1}))))  -- structName
                                   (Just [CDecl 
                                          [CTypeSpec (CIntType (NodeInfo ("test.c": line 4) (("test.c": line 4),3) (Name {nameId = 3})))] 
                                          [(Just (CDeclr (Just (Ident "x_0" 798712 (NodeInfo ("test.c": line 4) (("test.c": line 4),3) (Name {nameId = 2})))) [] Nothing [] (NodeInfo ("test.c": line 4) (("test.c": line 4),3) (Name {nameId = 4}))),Nothing,Nothing)] 
                                          (NodeInfo ("test.c": line 4) (("test.c": line 4),3) (Name {nameId = 5}))
                                               
                                         ,CDecl 
                                          [CTypeSpec (CIntType (NodeInfo ("test.c": line 5) (("test.c": line 5),3) (Name {nameId = 6})))] 
                                          [(Just (CDeclr (Just (Ident "cond2" 211531797 (NodeInfo ("test.c": line 5) (("test.c": line 5),5) (Name {nameId = 7})))) [CPtrDeclr [] (NodeInfo ("test.c": line 5) (("test.c": line 5),5) (Name {nameId = 9})),CFunDeclr (Right ([CDecl [CTypeSpec (CSUType (CStruct CStructTag (Just (Ident "FibCtxt" 144044346 (NodeInfo ("test.c": line 5) (("test.c": line 5),7) (Name {nameId = 10})))) Nothing [] (NodeInfo ("test.c": line 5) (("test.c": line 5),7) (Name {nameId = 11}))) (NodeInfo ("test.c": line 5) (("test.c": line 5),7) (Name {nameId = 12})))] [(Just (CDeclr Nothing [CPtrDeclr [] (NodeInfo ("test.c": line 5) (("test.c": line 5),1) (Name {nameId = 13}))] Nothing [] (OnlyPos <no file> (<no file>,-1))),Nothing,Nothing)] (NodeInfo ("test.c": line 5) (("test.c": line 5),1) (Name {nameId = 14}))],False)) [] (NodeInfo ("test.c": line 5) (("test.c": line 5),1) (Name {nameId = 15}))] Nothing [] (NodeInfo ("test.c": line 5) (("test.c": line 5),5) (Name {nameId = 8}))),Nothing,Nothing)] 
                                          (NodeInfo ("test.c": line 5) (("test.c": line 5),1) (Name {nameId = 16}))
                                               
                                         ,CDecl 
                                          [CTypeSpec (CVoidType (NodeInfo ("test.c": line 6) (("test.c": line 6),4) (Name {nameId = 17})))] 
                                          [(Just (CDeclr (Just (Ident "visitor3" 330935530 (NodeInfo ("test.c": line 6) (("test.c": line 6),8) (Name {nameId = 18})))) [CPtrDeclr [] (NodeInfo ("test.c": line 6) (("test.c": line 6),8) (Name {nameId = 20})),CFunDeclr (Right ([CDecl [CTypeSpec (CVoidType (NodeInfo ("test.c": line 6) (("test.c": line 6),4) (Name {nameId = 21})))] [(Just (CDeclr (Just (Ident "k" 107 (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 22})))) [CPtrDeclr [] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 24})),CFunDeclr (Right ([CDecl [CTypeSpec (CSUType (CStruct CStructTag (Just (Ident "FibCtxt" 144044346 (NodeInfo ("test.c": line 6) (("test.c": line 6),7) (Name {nameId = 25})))) Nothing [] (NodeInfo ("test.c": line 6) (("test.c": line 6),7) (Name {nameId = 26}))) (NodeInfo ("test.c": line 6) (("test.c": line 6),7) (Name {nameId = 27})))] [(Just (CDeclr Nothing [CPtrDeclr [] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 28}))] Nothing [] (OnlyPos <no file> (<no file>,-1))),Nothing,Nothing)] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 29}))],False)) [] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 30}))] Nothing [] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 23}))),Nothing,Nothing)] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 31})),CDecl [CTypeSpec (CSUType (CStruct CStructTag (Just (Ident "FibCtxt" 144044346 (NodeInfo ("test.c": line 6) (("test.c": line 6),7) (Name {nameId = 32})))) Nothing [] (NodeInfo ("test.c": line 6) (("test.c": line 6),7) (Name {nameId = 33}))) (NodeInfo ("test.c": line 6) (("test.c": line 6),7) (Name {nameId = 34})))] [(Just (CDeclr Nothing [CPtrDeclr [] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 35}))] Nothing [] (OnlyPos <no file> (<no file>,-1))),Nothing,Nothing)] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 36}))],False)) [] (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 37}))] Nothing [] (NodeInfo ("test.c": line 6) (("test.c": line 6),8) (Name {nameId = 19}))),Nothing,Nothing)] 
                                          (NodeInfo ("test.c": line 6) (("test.c": line 6),1) (Name {nameId = 38}))]) 
                                   [] 
                                   (NodeInfo ("test.c": line 3) (("test.c": line 7),1) (Name {nameId = 40}))) 
                          (NodeInfo ("test.c": line 3) (("test.c": line 7),1) (Name {nameId = 41})))
                   ] 
             -- mb_declarator,mb_init,mib
             [(Just (CDeclr (Just (Ident "fibctxt" 211153242 (NodeInfo ("test.c": line 7) (("test.c": line 7),7) (Name {nameId = 39})))) [] Nothing [] (NodeInfo ("test.c": line 7) (("test.c": line 7),7) (Name {nameId = 42}))),Nothing,Nothing)] 
             (NodeInfo ("test.c": line 3) (("test.c": line 7),1) (Name {nameId = 43})))] 
  (NodeInfo ("test.c": line 3) (("test.c": line 7),1) (Name {nameId = 44}))


-}

