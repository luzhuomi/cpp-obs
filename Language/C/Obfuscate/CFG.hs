{-# LANGUAGE FlexibleInstances #-} 

-- constructing a control flow graph from a C source file

module Language.C.Obfuscate.CFG 
       where

import qualified Data.Map as M
import qualified Data.Set as S
import Data.List (nub)
import Data.Char (isDigit)
import qualified Language.C.Syntax.AST as AST
import qualified Language.C.Data.Node as N 
import Language.C.Syntax.Constants
import Language.C.Data.Ident

import Control.Applicative
import Control.Monad.State as M hiding (State)
-- the data type of the control flow graph

import Language.C.Obfuscate.ASTUtils


-- import for testing
import Language.C (parseCFile, parseCFilePre)
import Language.C.System.GCC (newGCC)
import Language.C.Pretty (pretty)

import System.IO.Unsafe (unsafePerformIO)

import Text.PrettyPrint.HughesPJ (render, text, (<+>), hsep)

testCFG = do 
  { let opts = []
  ; ast <- errorOnLeftM "Parse Error" $ parseCFile (newGCC "gcc") Nothing opts "test/lastwhile.c"
  ; case ast of 
    { AST.CTranslUnit (AST.CFDefExt fundef:_) nodeInfo -> 
         case runCFG fundef of
           { CFGOk (_, state) -> putStrLn $ show (cfg state)
           ; CFGError s       -> error s
           }
    ; _ -> error "not fundec"
    }
  }

errorOnLeft :: (Show a) => String -> (Either a b) -> IO b
errorOnLeft msg = either (error . ((msg ++ ": ")++).show) return

errorOnLeftM :: (Show a) => String -> IO (Either a b) -> IO b
errorOnLeftM msg action = action >>= errorOnLeft msg




type FunDef   = AST.CFunctionDef N.NodeInfo
type Stmt     = AST.CStatement N.NodeInfo
type CFG      = M.Map NodeId Node


lookupCFG :: NodeId -> CFG -> Maybe Node 
lookupCFG id cfg = M.lookup id cfg


data SwitchOrLoop = Neither
  | IsSwitch [NodeId] [NodeId] 
  | IsLoop [NodeId] [NodeId] 
  deriving Show

                          
data Node = Node { stmts   :: [AST.CCompoundBlockItem N.NodeInfo] -- ^ a compound stmt
                 , lVars :: [Ident] -- ^ all the lval variables, e.g. x in x = y; x in x[i] = y
                 , rVars :: [Ident] -- ^ all the rval variables, e.g. y in x = y; i and y in x[i] = y
                 , localDecls :: [Ident] -- ^ all the variables that are declared locally in this node.
                 , preds   :: [NodeId]
                 , succs   :: [NodeId]
                 , switchOrLoop  :: SwitchOrLoop       -- ^ to indicate whether a if node is desugared from a loop (while / for loop)
                 } 
                   

instance Show Node where
  show (Node stmts lhs rhs local_decls preds succs loop) = 
    "\n Node = (stmts: " ++ (show (map (render . pretty) stmts)) ++ "\n preds: " 
    ++ (show preds) ++ "\n succs: " 
    ++ (show succs) ++  "\n lVars: " ++ (show lhs) ++ "\n rVars: " ++ (show rhs) ++  "\n localDecls: " ++ (show local_decls) ++ ")\n"

type NodeId = Ident



-- we use state monad for the ease of reporting error and keep track of the environment passing
data StateInfo = StateInfo { currId :: Int -- ^ next available int for generating the next nodeid
                           , cfg :: CFG
                           , currPreds ::[NodeId]
                           , continuable :: Bool
                           -- , stmtUpdate :: M.Map NodeId (Ident -> Node -> Node) -- ^ callback to update the stmt in predecessor, used in case of while, if and goto
                           , contNodes :: [NodeId]
                           , breakNodes :: [NodeId]
                           , caseNodes :: [CaseExp] -- case node
                           , formalArgs :: [Ident] -- formal arguments
                           , fallThroughCases :: [(AST.CExpression N.NodeInfo)]
                           } deriving Show
                 
-- instance Show StateInfo where                 
--   show (StateInfo cId cfg currPreds continuable) = show cId ++ "\t" ++ show cfg


data CaseExp = DefaultCase 
               NodeId -- ^ the wrapper if statement node id in the translated AST
               NodeId -- ^ rhs node id
               
             | ExpCase 
               (AST.CExpression N.NodeInfo) -- ^ the exp being checked against
               [(AST.CExpression N.NodeInfo)]  -- ^ the preceding "fall-through" cases with empty exp if any
               NodeId -- ^ the wrapper if statement node id in the translated AST
               NodeId -- ^ rhs node id               
             deriving Show

wrapperId :: CaseExp -> NodeId 
wrapperId (DefaultCase l _ ) = l
wrapperId (ExpCase e es l _ ) = l


labPref :: String
labPref = "myLabel"

-- remove the label pref to obtain int id, if not possible use the id name string hash
unLabPref :: Ident -> Integer
unLabPref (Ident s hash _) = 
  let suf = drop (length labPref) s
  in if (not (null suf)) && (all isDigit suf)
     then read suf
     else fromIntegral hash



initStateInfo = StateInfo 0 M.empty [] False [] [] [] [] []



data CFGResult a  = CFGError String
                  | CFGOk a
                  deriving Show
                   
instance Functor CFGResult where
  -- fmap  :: (a -> b) -> CFGResult a -> CFGResult b
  fmap f ma = case ma of
    { CFGOk a -> CFGOk (f a)
    ; CFGError s -> CFGError s
    }
  
instance Applicative CFGResult where
  pure x = CFGOk x
  -- (<*>) :: CFGResult (a -> b) -> CFGResult a -> CFGResult b
  mf <*> ma = case mf of  
    { CFGOk f -> case ma of 
         { CFGOk a -> CFGOk (f a)
         ; CFGError s -> CFGError s
         }
    ; CFGError s -> CFGError s
    }
              
instance Alternative CFGResult where
  empty = CFGError "error"
  p <|> q = case p of 
    { CFGOk x -> CFGOk x
    ; CFGError s -> q 
    }
              

instance Monad CFGResult where
  return x = CFGOk x
  p >>= q  = case p of 
    { CFGOk a -> q a
    ; CFGError s -> CFGError s
    }
  fail mesg = CFGError mesg

instance MonadPlus CFGResult where 
  mzero = CFGError "error"
  p `mplus` q = case p of 
    { CFGOk a    -> CFGOk a
    ; CFGError _ ->  q
    }


type State s = M.StateT s CFGResult


runCFG :: AST.CFunctionDef N.NodeInfo -> CFGResult ((), StateInfo)
runCFG fundef = 
  runStateT (buildCFG fundef) initStateInfo
          

-- build a partial CFG, it is "partial" in the sense that 
-- 1) the original goto are not yet connected to the labeled block
--      i.e. labeled block's preds list is yet to include the goto's block label
-- 2) the succs of the continue and break blocks yet need to updated
--      but the continue and break's block label should be associated with the parent (switch or loop) block label
-- 3) the gotos need to be generated non-goto block (end of the block, a "goto succLabel" is required to be inserted before SSA to be built)

class CProg a  where
  buildCFG :: a -> State StateInfo ()
  
instance CProg (AST.CFunctionDef N.NodeInfo)  where
  buildCFG (AST.CFunDef tySpecfs declarator decls stmt nodeInfo)  = do {- stmt must be compound -} 
    { buildCFG stmt 
    ; st <- get
    ; let fargs = concatMap getFormalArgIds (getFormalArgsFromDeclarator declarator)
    ; put st{ cfg = formalArgsAsDecls fargs (insertPhantoms (insertGotos (cfg st)))
            , formalArgs = fargs}
    ; return ()
    }
  

-- CFG, newNodeId, predIds, continuable |- stmt => CFG', newNodeId', predIds', continuable'

instance CProg (AST.CStatement N.NodeInfo) where
{-
CFG1 = CFG \update { pred : { succ = l } } \union { l : { stmts = goto max; } 
// todo maybe we shall add this goto statement later
CFG1, max, {l}, false |- stmt => CFG2, max2, preds, continuable
------------------------------------------------------------------------------
CFG, max, preds, _ |- l: stmt => CFG2, max2, preds, continuable


-}
  
  buildCFG (AST.CLabel label stmt attrs nodeInfo) = do 
    { st <- get 
    ; let max        = currId st
          currNodeId = internalIdent (labPref++show max)
          cfg0       = cfg st 
          preds0     = currPreds st
          cfgNode    = Node [AST.CBlockStmt $ (AST.CGoto currNodeId nodeInfo) ] [] [] [] preds0 [] Neither  -- todo attrs are lost
          cfg1       = M.insert label cfgNode $ 
                       foldl (\g pred -> M.update (\n -> Just n{succs = [label]}) pred g) cfg0 preds0
    ; put st{cfg = cfg1, currPreds=[label], continuable = False}
    ; buildCFG stmt 
    }
{-
CFG, max, preds, continuable, breakNodes, contNodes, caseNodes |- stmt => CFG2, max2, preds2, continuable2, breakNodes2, contNodes2, caseNodes2 
------------------------------------------------------------------------------------------------------------------------------------------------------------------ 
CFG,max,preds, continuable, breakNodes, contNodes, caseNodes |- case e: stmt => CFG2, max2, preds2 continuable2, breakNodes, contNodes2, caseNodes2 \union (max, e) 
-}
  
  buildCFG (AST.CCase exp stmt nodeInfo) = 
    if (isCaseStmt stmt)  
    then do 
        {- empty fall through case,
            case 2:
            case 3: e
          -}
      { st <- get
      ; let fallThrough = fallThroughCases st
      ; put st{fallThroughCases=fallThrough ++ [ exp ]}
      ; buildCFG stmt
      }
    else do 
      { st <- get
      ; let max        = currId st
            fallThrough = fallThroughCases st
            wrapNodeId = internalIdent (labPref++show max) -- reserved for the wraper if statement in the translation
            rhsNodeId = internalIdent (labPref++show (max+1))          
      ; put st{currId = max + 1, fallThroughCases=[]} -- empty the fallthru
      ; buildCFG stmt 
      ; st1 <- get
      ; put st1{caseNodes=(caseNodes st1)++[(ExpCase exp fallThrough wrapNodeId rhsNodeId)]}
      }

  buildCFG (AST.CCases lower upper stmt nodeInfo) = 
    fail $ (posFromNodeInfo nodeInfo) ++ " range case stmt not supported."
{-
CFG, max, preds, continuable, breakNodes, contNodes, caseNodes |- stmt => CFG2, max2, preds2, continuable2, breakNodes2, contNodes2, caseNodes2 
------------------------------------------------------------------------------------------------------------------------------------------------------------------ 
CFG,max,preds, continuable, breakNodes, contNodes, caseNodes |- default: stmt => CFG2, max2, preds2 continuable2, breakNodes, contNodes2, caseNodes2 \union (max, default) 
-}
  buildCFG (AST.CDefault stmt nodeInfo) = do
    { st <- get
    ; let max        = currId st
          wrapNodeId = internalIdent (labPref++show max) -- reserved for the wraper if statement in the translation
          rhsNodeId = internalIdent (labPref++show (max+1))          
    ; put st{currId = max + 1, fallThroughCases=[]}          
    ; buildCFG stmt 
    ; st1 <- get
    ; put st1{caseNodes=(caseNodes st1)++[(DefaultCase wrapNodeId rhsNodeId)]}
    }
                                          
{-
CFG1 = CFG \update { pred : {stmts = stmts ++ [x = exp], lVars = lVars ++ [x] } }  
x \not in {v | v \in lVars pred, pred \in preds }
--------------------------------------------------------
CFG, max, preds, true |-  x = exp => CFG1, max, [] , true 

max1 = max + 1
CFG1 = CFG \update { pred : {succ = max} |  pred <- preds } \union { max : {x = exp} } 
--------------------------------------------------------
CFG, max, preds, false |- x = exp => CFG1, max1, [], false 
-}
  
  buildCFG (AST.CExpr (Just exp@(AST.CAssign op lval rval nodeInfo1)) nodeInfo) = do  -- todo : what about lhs += rhs
    { st <- get
    ; let (lhs,rhs)= getVarsFromExp exp
          cfg0     = cfg st
          preds0   = currPreds st
          lhsPreds = S.fromList $ concatMap (\pred -> case (M.lookup pred cfg0) of 
                                                { Just n -> lVars n 
                                                ; Nothing -> [] 
                                                }) preds0
          s        = AST.CBlockStmt $ AST.CExpr (Just (AST.CAssign op lval rval nodeInfo1) ) nodeInfo
    ; if (continuable st && not (any (\x -> x `S.member` lhsPreds) lhs))
      then 
        let cfg1       = foldl (\g pred -> M.update (\n -> Just n{stmts=(stmts n) ++ [ s ], lVars=(lVars n)++lhs, rVars=(rVars n)++rhs}) pred g) cfg0 preds0
        in do { put st{cfg = cfg1, continuable = True} }   

      else 
        let max        = currId st
            currNodeId = internalIdent (labPref++show max)          
            max1       = max + 1
            cfgNode    = Node [s] lhs rhs [] preds0 [] Neither
            cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n)++[currNodeId]} ) pred g) cfg0 preds0
            cfg1       = M.insert currNodeId cfgNode cfg1'
        in do { put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = True} }
    }
  buildCFG (AST.CExpr (Just (AST.CUnary AST.CPreIncOp e nodeInfo')) nodeInfo) = 
    -- todo: i++ ==> (i=i+1)-1
    -- done: ++i ==> i=i+1
    buildCFG (AST.CExpr (Just (AST.CAssign AST.CAssignOp e (AST.CBinary AST.CAddOp e (AST.CConst (AST.CIntConst (cInteger 1) N.undefNode)) nodeInfo') nodeInfo')) nodeInfo)
  buildCFG (AST.CExpr (Just (AST.CUnary AST.CPostIncOp e nodeInfo')) nodeInfo) = 
    buildCFG (AST.CExpr (Just (AST.CAssign AST.CAssignOp e (AST.CBinary AST.CAddOp e (AST.CConst (AST.CIntConst (cInteger 1) N.undefNode)) nodeInfo') nodeInfo')) nodeInfo)
  buildCFG (AST.CExpr (Just (AST.CUnary AST.CPreDecOp e nodeInfo')) nodeInfo) = 
    buildCFG (AST.CExpr (Just (AST.CAssign AST.CAssignOp e (AST.CBinary AST.CSubOp e (AST.CConst (AST.CIntConst (cInteger 1) N.undefNode)) nodeInfo') nodeInfo')) nodeInfo)
  buildCFG (AST.CExpr (Just (AST.CUnary AST.CPostDecOp e nodeInfo')) nodeInfo) = 
    buildCFG (AST.CExpr (Just (AST.CAssign AST.CAssignOp e (AST.CBinary AST.CSubOp e (AST.CConst (AST.CIntConst (cInteger 1) N.undefNode)) nodeInfo') nodeInfo')) nodeInfo)
  -- not assigment, pretty much the same as the assignment expression except that we don't care about the lhs vars
  buildCFG (AST.CExpr (Just (AST.CComma exps ni')) ni) = mapM_ buildCFG (map (\exp -> (AST.CExpr (Just exp) ni)) exps)
  buildCFG (AST.CExpr (Just exp) nodeInfo) =  do  
    { st <- get
    ; let cfg0     = cfg st
          (lhs,rhs) = getVarsFromExp exp
          preds0   = currPreds st
          s        = AST.CBlockStmt $ AST.CExpr (Just exp) nodeInfo
    ; if (continuable st)
      then 
        let cfg1       = foldl (\g pred -> M.update (\n -> Just n{stmts=(stmts n) ++ [ s ], lVars=(lVars n)++lhs, rVars = (rVars n) ++ rhs}) pred g) cfg0 preds0
        in do { put st{cfg = cfg1, continuable = True} }   
      else 
        let max        = currId st
            currNodeId = internalIdent (labPref++show max)          
            max1       = max + 1
            cfgNode    = Node [s] [] rhs [] preds0 [] Neither
            cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n)++[currNodeId]} ) pred g) cfg0 preds0
            cfg1       = M.insert currNodeId cfgNode cfg1'
        in do { put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = True} }
    }
  
  buildCFG (AST.CExpr Nothing nodeInfo) = return () -- todo: check
    {-    
max1 = max + 1
l0' = max
CFG1 = CFG \update { pred : { succ = {max} } } \union { l0' : { stmts = { if (exp == e1) { goto l1; } else { goto l1'; } }}, succs = { l1,l1'}, preds = preds }  \update { l1: { preds += l0' } }
                                               \union { l1' : { stmts = { if (exp == e2) { goto l2; } else { goto l2'; } }}, succs = { l2,l2'}, preds = {l0'} }  \update { l2: { preds += l1' } }
                                               \union { l2' : { stmts = { if (exp == e3) { goto l3; } else { goto l3'; } }}, succs = { l3,l3'}, preds = {l1'} }  \update { l3: { preds += l2' } }
                                               ... 
                                               \union { ln-1' : { stmts = { if (exp == en) { goto ln; } else { goto l_default; }}, succs = { ln, l_default }, preds = {ln-2'} } \update { ln- : { preds += ln-1' }} \update { l_default : { preds += ln-1' } } 

CFG1, max1, {}, false, {}, contNodes, {} |- stmt1,..., stmtn+1 => CFG2, max2, preds2, continable2, breakNodes, contNodes2, {(l1,l1',e1),...,(l_default, _)} 
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, continuable, breakNodes, contNodes, caseNodes |- switch exp { stmt1,...,stmtn }   => CFG2, max2, preds2 \union breakNodes2 , false, breakNodes, contNodes2, caseNodes
-}
  buildCFG (AST.CCompound localLabels blockItems nodeInfo) =
    if (null blockItems)  
    then do 
      { st <- get
      ; let max        = currId st
            currNodeId = internalIdent (labPref++show max)          
            lhs        = []
            rhs        = []
            max1       = max + 1
            cfg0       = cfg st 
            preds0     = currPreds st
            cfgNode    = Node [] lhs rhs [] preds0 [] Neither
            cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg0 preds0
            cfg1       = M.insert currNodeId cfgNode cfg1'
      ; put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = False}
      }
    else do 
      { mapM_ buildCFG blockItems
      ; if (not (null blockItems)) 
        then case last blockItems of 
          { AST.CBlockStmt stmt | isWhileStmt stmt ->
           -- the last blockItem is a while. e.g. 
           {-
int f() {
  int c = 0;
  while (1) {
    if (c > 10)
      return c;
    c++;      
  }
  1 == 1; // inserted automatically
}
-}
               let one = AST.CConst (AST.CIntConst (cInteger 1) N.undefNode) 
               in buildCFG (AST.CExpr (Just (one .==. one)) N.undefNode) 
               -- buildCFG (AST.CReturn Nothing N.undefNode) -- does not work if the function's return type is not void
          ; _ -> return () 
          }
        else return ()
      }
{-
to handle cases of  multi-line macro rhs declarations like
if (1) {
  stmts
}
-}
  buildCFG (AST.CIf (AST.CConst (AST.CIntConst one nodeInf)) compound Nothing nodeInf') | getCInteger one == 1 = buildCFG compound
  -- empty true statment
  {- if e { ; } else { s } ---> if (!e) { s } -}
  buildCFG (AST.CIf exp trueStmt (Just falseStmt) nodeInfo) | isEmptyStmt trueStmt = {- let io = unsafePerformIO (putStrLn (show nodeInfo)) in io `seq` -} buildCFG (AST.CIf (cnot exp) falseStmt Nothing nodeInfo)
  buildCFG (AST.CIf exp trueStmt mbFalseStmt nodeInfo) = 
    case mbFalseStmt of 
{-  
max1 = max + 1
CFG1 = CFG \update { pred : {succ = max} |  pred <- preds } \union { max : { stmts =  [ if exp { goto max1 } else { goto max2 } ], succ = [], preds = preds} }
CFG1, max1, {max}, false |-n trueStmt => CFG2, max2, preds1, _ 
CFG2, max2, {max}, false |-n falseStmt => CFG3, max3, preds2, _
-------------------------------------------------------------------------------------------------------------
CFG, max, preds, _ |- if exp { trueStmt } else { falseStmt }  => CFG3, max3, preds1 U preds2, false
-}      
      { Just falseStmt -> do 
           { st <- get 
           ; let max        = currId st
                 currNodeId = internalIdent (labPref++show max)          
                 (lhs,rhs)  = getVarsFromExp exp
                 max1       = max + 1
                 cfg0       = cfg st 
                 preds0     = currPreds st
                 -- note: we dont have max2 until we have CFG1
                 -- CFG1, max1, {max}, false |-n trueStmt => CFG2, max2, preds1, _ 
                 -- we can give an empty statement to the new CFG node in CFG1 first and update it
                 -- after we have max2,
                 cfgNode    = Node [] lhs rhs [] preds0 [] Neither
                 cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg0 preds0
                 cfg1       = M.insert currNodeId cfgNode cfg1'
                              
           ; put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = False}
           ; buildCFG trueStmt
           ; st1 <- get
           ; let max2      = currId st1
                 preds1    = currPreds st1
                 s         = AST.CBlockStmt $ AST.CIf exp  
                             (AST.CGoto (internalIdent (labPref ++ show max1)) nodeInfo) 
                             (Just (AST.CGoto (internalIdent (labPref ++ show max2)) nodeInfo)) nodeInfo
                 cfg2      = cfg st1
                 -- add the stmt back to the curr node (If statement)
                 cfg2'     = M.update (\n -> Just n{stmts=[s]}) currNodeId cfg2
           ; put st1{cfg = cfg2', currId=max2, currPreds=[currNodeId], continuable = False}
           ; buildCFG falseStmt
           ; st2 <- get
           ; let max3      = currId st2
                 preds2    = currPreds st2
                 cfg3      = cfg st2
           ; put st{cfg = cfg3, currId=max3, currPreds=preds1 ++ preds2, continuable = False}
           }
{-  
CFG, max, preds, continuable |- if exp { trueStmt } else { nop } => CFG', max', preds', continuable' 
-------------------------------------------------------------------------------------------------------------
CFG, max, preds, continuable |- if exp { trueStmt }   => CFG', max', preds', continuable' 
-}                                
      ; Nothing -> buildCFG (AST.CIf exp trueStmt (Just $ AST.CCompound [] [] nodeInfo) nodeInfo) 
      }
{-    
CFG, max, {}, false, {}, contNodes, {} |- stmt1,..., stmtn+1 => CFG1, max1, preds1, continable1, breakNodes1, contNodes1, {(l1,l1',e1),...,(l_default, _)} 
l0' = max1
CFG2 = CFG1 \update { pred : { succ = {max} } } \union { l0' : { stmts = { if (exp == e1) { goto l1; } else { goto l1'; } }}, succs = { l1,l1'}, preds = preds }  \update { l1: { preds += l0' } }
                                               \union { l1' : { stmts = { if (exp == e2) { goto l2; } else { goto l2'; } }}, succs = { l2,l2'}, preds = {l0'} }  \update { l2: { preds += l1' } }
                                               \union { l2' : { stmts = { if (exp == e3) { goto l3; } else { goto l3'; } }}, succs = { l3,l3'}, preds = {l1'} }  \update { l3: { preds += l2' } }
                                               ... 
                                               \union { ln-1' : { stmts = { if (exp == en) { goto ln; } else { goto l_default; }}, succs = { ln, l_default }, preds = {ln-2'} } \update { ln- : { preds += ln-1' }} \update { l_default : { preds += ln-1' } } 
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, continuable, breakNodes, contNodes, caseNodes |- switch exp { stmt1,...,stmtn }   => CFG2, ln-1', preds1 \union breakNodes1 , false, breakNodes, contNodes1, caseNodes
-}

  buildCFG (AST.CSwitch exp swStmt nodeInfo) = do 
    { st <- get 
    ; let max = currId st
          currNodeId = internalIdent (labPref++show max)          
          (lhs,rhs)  = getVarsFromExp exp          
          max1       = max + 1
          l0         = max
          cfg0       = cfg st 
          preds0     = currPreds st
          contNodes0 = contNodes st
          breakNodes0 = breakNodes st
          caseNodes0 = caseNodes st
    ; put st{currPreds=[], fallThroughCases=[], continuable = False, breakNodes = [], caseNodes = [] }
    ; buildCFG swStmt
    ; st1 <- get 
    ; let
          preds1 = breakNodes st1
          breakNodes1 = breakNodes st1
          caseNodes1 = caseNodes st1
          
          -- this function has to be in the monad, because we only have the label of each case statement, but not the node.
          caseExpsToIfNodes ::  [CaseExp] ->  
                                State StateInfo [NodeId] -- the returned list node ids capture last leaving (if wrapper) node, in case there is no default case 
          caseExpsToIfNodes [] = return [] 
          caseExpsToIfNodes ((DefaultCase wrapNodeId rhsNodeId):_) = do 
            { st <- get
            ; let preds0 = currPreds st
                  cfg0 = cfg st 
                  -- currNodeId = internalIdent (labPref++show max)   
                  stmts = [AST.CBlockStmt (AST.CGoto rhsNodeId N.undefNode)]
                  cfgNode = Node stmts [] [] [] preds0 [rhsNodeId] Neither 
                  cfg0' = M.update (\n -> Just n{preds = nub ((preds n) ++ [wrapNodeId])}) rhsNodeId cfg0 
                  cfg0'' = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [wrapNodeId]}) pred g) cfg0' preds0
                  cfg1 = M.insert wrapNodeId cfgNode cfg0''
            ; put st{cfg = cfg1, currPreds=[wrapNodeId], continuable = False}
            ; return [] -- no extra predessor id to pass
            }
          caseExpsToIfNodes ((ExpCase e es wrapNodeId rhsNodeId):next:ps)= do 
            { st <- get
            ; let preds0 = currPreds st
                  cfg0 = cfg st 
                  nextNodeId = wrapperId next
                  (lhs',rhs')  = case (unzip (map getVarsFromExp (e:es))) of { (ls, rs) -> (concat ls, concat rs) }
                  -- (lhs',rhs')  = getVarsFromExp e
                  cond = foldl (\a e -> ((exp .==. e) .||. a)) (exp .==. e) es 
                  stmts = [AST.CBlockStmt (AST.CIf cond (AST.CGoto rhsNodeId N.undefNode) (Just (AST.CGoto nextNodeId N.undefNode)) N.undefNode)]
                  cfgNode = Node stmts (nub $ lhs ++ lhs') (nub $ rhs ++ rhs') [] preds0 [rhsNodeId,nextNodeId] Neither 
                  cfg0' = M.update (\n -> Just n{preds = nub $ (preds n) ++ [wrapNodeId]}) rhsNodeId cfg0                  
                  cfg0'' = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [wrapNodeId]}) pred g) cfg0' preds0
                  cfg1 = M.insert wrapNodeId cfgNode cfg0''
            ; put st{cfg = cfg1, currPreds=[wrapNodeId], continuable = False}
            ; caseExpsToIfNodes (next:ps)
            }
          caseExpsToIfNodes [(ExpCase e es wrapNodeId rhsNodeId)]= do 
            { st <- get
            ; let preds0 = currPreds st
                  cfg0 = cfg st 
                  max  = currId st
                  -- nextNodeId = internalIdent (labPref++show max)
                  (lhs',rhs')  = case (unzip (map getVarsFromExp (e:es))) of { (ls, rs) -> (concat ls, concat rs) }
                  -- (lhs',rhs')  = getVarsFromExp e

                  -- stmts = [AST.CBlockStmt (AST.CIf (exp .==. e) (AST.CGoto rhsNodeId N.undefNode) (Just (AST.CGoto nextNodeId N.undefNode)) N.undefNode)] -- problem, the following statement is not neccessarily max2, i.e. the next available num. the next available num can be used in a sibling block, e.g. the current loop is in then branch, the next available int is usined in the else branch

                  cond = foldl (\a e -> ((exp .==. e) .||. a)) (exp .==. e) es 
                  stmts = [AST.CBlockStmt (AST.CIf cond (AST.CGoto rhsNodeId N.undefNode) Nothing N.undefNode)] -- leaving the else as Nothing first. We will update it to the right goto at insertGT after the succs of this node is updated.
                  cfgNode = Node stmts (nub $ lhs ++ lhs') (nub $ rhs ++ rhs') [] preds0 [rhsNodeId{-,nextNodeId-} ] Neither 
                  cfg0' = M.update (\n -> Just n{preds = nub $ (preds n) ++ [wrapNodeId]}) rhsNodeId cfg0                  
                  cfg0'' = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [wrapNodeId]}) pred g) cfg0' preds0
                  cfg1 = M.insert wrapNodeId cfgNode cfg0''
            ; put st{cfg = cfg1, currPreds=[wrapNodeId], continuable = False}
            ; return [wrapNodeId] -- this is the last case exp (not a default), due to the if test, in case of false, we go to the following statement after the switch block
            }
                                                                        
      ; put st1{currPreds = preds0}
      ; mb_preds <- caseExpsToIfNodes caseNodes1
      ; st2 <- get
      ; put st2{currPreds = preds1 ++ breakNodes1 ++ mb_preds, continuable = False, breakNodes = breakNodes0, caseNodes=caseNodes0 }
    }



{-    old way
max1 = max + 1
CFG1 = CFG \update { pred : { succ = {max} } } \union { max : { stmts = { if (exp == e1) { goto l1; } else if (exp == e2) { goto l2; } ... else { goto ldefault; } } },
                                                                succs = {l1,l2,...,ldefault}, preds = preds }
CFG1, max1, {max}, false, {}, contNodes, {} |- stmt1,..., stmtn => CFG2, max2, preds2, continable2, breakNodes, contNodes2, {(l1,e1),...,(l_default, _)} 
CFG2' = CFG2 \update { { l : { preds = {max} } } | l \in {l1,...,l_default} and preds(l) \intersect breakNodes2 != {} } 
             \update { { l : { preds = preds \union {max} } | l \in {l1,...,l_default} and preds(l) \intersect breakNodes2 == {} } 
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, continuable, breakNodes, contNodes, caseNodes |- switch exp { stmt1,...,stmtn }   => CFG2', max2, preds2 \union breakNodes2 , false, breakNodes, contNodes2, caseNodes
-}
{-    
    { st <- get 
    ; let max = currId st
          currNodeId = internalIdent (labPref++show max)          
          (lhs,rhs)  = getVarsFromExp exp          
          max1       = max + 1
          cfg0       = cfg st 
          preds0     = currPreds st
          contNodes0 = contNodes st
          breakNodes0 = breakNodes st
          caseNodes0 = caseNodes st
          -- note: we dont have max2 and preds1 until we have CFG1
          -- CFG1, max1, {max}, false, {}, contNodes, {} |- stmt1,..., stmtn => CFG2, max2, preds2, continable2, breakNodes, contNodes2, {(l1,e1),...,(l_default, _)} 
          -- we can give an empty statement to the new CFG node in CFG1 first and update it
          -- after we have max2,          
          cfgNode = Node [] lhs rhs [] preds0 [] Neither
          cfg1'   = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg0 preds0 
          cfg1    = M.insert currNodeId cfgNode cfg1'
    ; put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = False, breakNodes = [], caseNodes = [] }
    ; buildCFG swStmt
    ; st1 <- get 
    ; let max2 = currId st1
          cfg2 = cfg st1
          breakNodes2 = breakNodes st1
          caseNodes2 = caseNodes st1
          newLabs    = (M.fromList caseNodes2) -- cfg2 `M.difference` cfg1
          newLabsWBreaks = newLabs `M.intersection` (M.fromList (zip breakNodes2 (repeat ())))
          newLabsWoBreaks = newLabs `M.difference` (M.fromList (zip breakNodes2 (repeat ())))
          cfg2' = foldl (\g l -> M.update (\n -> Just n{preds = [currNodeId]}) l g) cfg2 (map fst $ M.toList newLabsWBreaks)
          cfg2'' = foldl (\g l -> M.update (\n -> Just n{preds = (preds n) ++ [currNodeId]}) l g) cfg2' (map fst $ M.toList newLabsWoBreaks)
          casesToIf cases = case cases of 
            { [] -> error "empty Switch statements"
            ; [(l,ExpCase e)] -> AST.CIf (exp .==. e) (AST.CGoto l nodeInfo) Nothing nodeInfo
            ; (l, DefaultCase):_ -> AST.CGoto l nodeInfo
            ; (l, ExpCase e):cases' -> AST.CIf (exp .==. e) (AST.CGoto l nodeInfo) (Just (casesToIf cases')) nodeInfo
            }
          cfg2''' = M.update (\n -> Just n{stmts = [ AST.CBlockStmt $ casesToIf caseNodes2 ], succs = (map (\(l,_) -> l) caseNodes2)}) currNodeId cfg2'' 
    ; put st1{cfg = cfg2''', currPreds = (currPreds st1) ++ breakNodes2, continuable=False, breakNodes = breakNodes0, caseNodes= caseNodes0}
    }
-}
  -- | switch statement @CSwitch selectorExpr switchStmt@, where
  -- @switchStmt@ usually includes /case/, /break/ and /default/
  -- statements
{-  
max1 = max + 1
CFG1 = CFG \update { pred : {succ = max} |  pred <- preds ++ preds1 } \union { max: { stmts = [ if exp { goto max1 } else { goto max2 } ] } }
CFG1, max1, {max}, false, {}, {} |-n stmt => CFG2, max2, preds1, _, contNodes2, breakNodes2,  
CFG3 = CFG2 \update { id : { succ = max} | id <- contNodes2 } \update { id : { succ = max2 } | id <- breakNodes2 } \update { max : { preds = preds ++ contNodes2 } }
----------------------------------------------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, _, contNodes, breakNodes |- while (exp) { stmt } => CFG3, max2, {max} ++ breakNodes2, false, contNodes, breakNodes  
    -- shouldn't be max2? no, should be max, because max2's block will be created after this statment
-}
  buildCFG (AST.CWhile exp stmt False nodeInfo) = do -- while
    { st <- get 
    ; let max        = currId st
          currNodeId = internalIdent (labPref++show max)          
          (lhs,rhs)  = getVarsFromExp exp          
          max1       = max + 1
          cfg0       = cfg st 
          preds0     = currPreds st
          contNodes0 = contNodes st
          breakNodes0 = breakNodes st
          -- note: we dont have max2 and preds1 until we have CFG1
          -- CFG1, max1, {max}, false |-n trueStmt => CFG2, max2, preds1, _ 
          -- we can give an empty statement to the new CFG node in CFG1 first and update it
          -- after we have max2,
          cfgNode    = Node [] lhs rhs [] preds0 [] (IsLoop [] [])
          cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg0 preds0
          cfg1       = M.insert currNodeId cfgNode cfg1'
    ; put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = False, contNodes = [], breakNodes = []}
    ; buildCFG stmt 
    ; st1 <- get
    ; let max2      = currId st1
          preds1    = currPreds st1
          {- s         = AST.CBlockStmt $ AST.CIf exp  
                      (AST.CGoto (internalIdent (labPref ++ show max1)) nodeInfo) 
                      (Just (AST.CGoto (internalIdent (labPref ++ show max2)) nodeInfo)) nodeInfo -- problem, the following statement is not neccessarily max2, i.e. the next available num. the next available num can be used in a sibling block, e.g. the current loop is in then branch, the next available int is usined in the else branch for instance
int search(int a[], int size, int x) {
  if (a) { // 0
    int i;  // 1
    for (i=0 /* // 2 */; i< size; i++) // 3
      {
	// 4
	if (a[i] == x) 
	  { 
	    return i; // 5
	  }
	// 6
	// 7 i++
      }
  }
  // 8 implicit else
  // 9
  return -1;
}
3 will have if ... { goto 4 } else { goto 8 } which is an else from the outer if statement 0.
the correct translation should be  if ... { goto 4 } else { goto 9 }
          -}
          s         = AST.CBlockStmt $ AST.CIf exp  
                      (AST.CGoto (internalIdent (labPref ++ show max1)) nodeInfo) 
                      Nothing nodeInfo -- we leave the else goto as Nothing first, we will fix it via insertGT when the succ is added.
          cfg2      = cfg st1
          cfg2'     = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg2 preds1
          breakNodes2 = breakNodes st1
          contNodes2  = contNodes st1
          -- add the stmt back to the curr node (If statement)
          cfg2''     = M.update (\n -> Just n{stmts=[s], preds=(preds n)++preds1++contNodes2, succs=nub $ (succs n) {-++[internalIdent (labPref++show max2)]-}, switchOrLoop=(IsLoop breakNodes2 contNodes2)}) currNodeId cfg2'  -- preds n == preds0, preds1 are exits nodes from the loop body, contNodes2 are the continuation nodes from loop body,
          cfg3       = foldl (\g l -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) l g) cfg2'' contNodes2 -- update the break and cont immediately
          cfg3'      = foldl (\g l -> M.update (\n -> Just n{succs = nub $ (succs n) {- ++ [internalIdent (labPref++show max2)]-}}) l g) cfg3 breakNodes2 
    ; put st1{cfg = cfg3', currId=max2, currPreds=[currNodeId] ++ breakNodes2, continuable = False, contNodes = contNodes0, breakNodes = breakNodes0}
    }

{-
to handle cases of  multi-line macro rhs declarations like
do {
  stmts
} while (0);
-}
  buildCFG (AST.CWhile (AST.CConst (AST.CIntConst zero nodeInf))  stmt True nodeInfo) | getCInteger zero == 0 = buildCFG stmt


{-  
CFG, max, preds, continuable |- stmt => CFG1, max1, preds1, false 
CFG1, max1, preds1, false, contNodes, breakNodes |- while (exp) { stmt } => CFG2, max2, preds2, continuable, contNodes', breakNodes'
--------------------------------------------------------------------------------------
CFG, max, preds, continuable, contNodes, breakNodes |- do  { stmt } while (exp) => CFG2, max2, {max}, false, contNodes', breakNodes'
-}
                                                  
  buildCFG (AST.CWhile exp stmt True nodeInfo) = do   -- do ... while 
    { buildCFG stmt
    ; buildCFG (AST.CWhile exp stmt False nodeInfo) -- todo remove labels in stmt
    }
                                                                                                  
                                                 
                                                 
{-  

CFG, max, preds, continuable |- init => CFG1, max1, preds1, continuable1 
CFG1, max1, preds1, continuable1 |- while (exp2) { stmt; exp3 } => CFG2, max2, preds2, continuabl2
---------------------------------------------------------------------------------------    
CFG, max, preds, true |- for (init; exp2; exp3) { stmt }  => CFG2, max', preds', continuable

-}


  buildCFG (AST.CFor init exp2 exp3 stmt nodeInfo) = do 
    { _ <- case init of 
         { Right decl   -> buildCFG decl
         ; Left Nothing -> return ()
         ; Left exp     -> buildCFG (AST.CExpr exp nodeInfo)
         } 
    ; let exp2'      = case exp2 of 
            { Nothing -> AST.CConst (AST.CIntConst (cInteger 1) nodeInfo) -- true
            ; Just exp -> exp
            }
          stmt'      = case exp3 of 
            { Nothing -> stmt
            ; Just exp -> appStmt stmt (AST.CExpr exp3 nodeInfo)
            }
    ; buildCFG (AST.CWhile exp2' stmt' False nodeInfo)
    }
    where appStmt stmt1 stmt2 = case stmt1 of
            { AST.CCompound localLabels blockItems nodeInfo1 -> AST.CCompound localLabels (blockItems ++ [AST.CBlockStmt stmt2]) nodeInfo1
            ; _ -> AST.CCompound [] [AST.CBlockStmt stmt1, AST.CBlockStmt stmt2] nodeInfo 
            }

  -- | for statement @CFor init expr-2 expr-3 stmt@, where @init@ is
  -- either a declaration or initi-- todo: don't we need to propogate the current preds?alizing expression
{-
-- check:don't we need to propogate the current preds? next statement in the lexical order won't be the succ of the goto
-- we need to update the node L is a successor, but node L might not yet be created. 

CFG1 = CFG \update { pred : {stmts = stmts ++ [goto L] } } 
--------------------------------------------------------
CFG, max, preds, true |- goto L => CFG1, max, [] , false  



max1 = max + 1
CFG1 = CFG \update { pred : {succ = max} |  pred <- preds } \union { max : {stmts = goto L, succ= {L} } } 
--------------------------------------------------------
CFG, max, preds, false |- goto L => CFG1, max1, [], false 
-}

  buildCFG (AST.CGoto ident nodeInfo) = do 
    { st <- get 
    ; if (continuable st) 
      then 
        let cfg0       = cfg st 
            preds0     = currPreds st
            s          = AST.CBlockStmt $ AST.CGoto ident nodeInfo
            cfg1      = foldl (\g pred -> M.update (\n -> Just n{stmts=(stmts n) ++ [ s ], succs=nub $ (succs n) ++ [ident]}) pred g) cfg0 preds0
        in do 
          { put st{cfg = cfg1, currPreds=[], continuable = False} }
      else 
        let max        = currId st
            currNodeId = internalIdent (labPref++show max)          
            max1       = max + 1
            cfg0       = cfg st 
            preds0     = currPreds st
            s          = AST.CBlockStmt $ AST.CGoto ident nodeInfo
            cfgNode    = Node [s] [] [] [] preds0 [ident] Neither
            cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n)++[currNodeId]} ) pred g) cfg0 preds0
            cfg1       = M.insert currNodeId cfgNode cfg1'
        in do 
          {  put st{cfg = cfg1, currId=max1, currPreds=[], continuable = False} }
    }
  buildCFG (AST.CGotoPtr exp nodeInfo) =  
    fail $ (posFromNodeInfo nodeInfo) ++ "goto pointer stmt not supported."
  buildCFG (AST.CCont nodeInfo) = do 
    { st <- get
    ; if (continuable st) 
      then 
{-  
CFG1 = CFG \update { pred: {stmts = stmts ++ [continue] } | pred <- preds } 
-----------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, true, contNode, breakNodes |- continue =>  CFG1, max, {}, false, contNode \union preds, breakNodes 
-}
        let cfg0 = cfg st
            preds0 = currPreds st
            s      = AST.CBlockStmt $ AST.CCont nodeInfo
            cfg1 = foldl (\g pred -> M.update (\n -> Just n{stmts = (stmts n) ++ [s]}) pred g) cfg0 preds0
        in do 
          { put st{cfg = cfg1, currPreds=[], continuable = False, contNodes =((contNodes st) ++ preds0)} }
      else
{-  
max1 = max + 1
CFG1 = CFG \update { pred: {succ = max} | pred <- preds } \union { max : { stmts = [ continue ], preds = preds, succ = [] } }  
-----------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, false, contNode, breakNodes |- continue =>  CFG1, max1, {max}, false, contNode \union { max }, breakNodes 
-}
        let max = currId st
            currNodeId = internalIdent (labPref ++ show max)
            max1 = max + 1
            cfg0 = cfg st
            preds0 = currPreds st
            s      = AST.CBlockStmt $ AST.CCont nodeInfo
            cfgNode = Node [s] [] [] [] preds0 [] Neither
            cfg1' = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg0 preds0
            cfg1  = M.insert currNodeId cfgNode cfg1'
        in do 
          { put st{cfg = cfg1, currId=max1, currPreds=[], continuable = False, contNodes = (contNodes st) ++ [currNodeId] } }
    }
    
  buildCFG (AST.CBreak nodeInfo) = do
    { st <- get
    ; if (continuable st) 
      then 
{-  
CFG1 = CFG \update { pred: {stmts = stmts ++ [break] } | pred <- preds } 
-----------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, true, contNodes, breakNodes |- break =>  CFG1, max, {}, false, contNodes, breakNode \union preds 
-}
        let cfg0 = cfg st
            preds0 = currPreds st
            s      = AST.CBlockStmt $ AST.CBreak nodeInfo
            cfg1 = foldl (\g pred -> M.update (\n -> Just n{stmts = (stmts n) ++ [s]}) pred g) cfg0 preds0
        in do 
          { put st{cfg = cfg1, currPreds=[], continuable = False, breakNodes =((breakNodes st) ++ preds0)} }
      else
{-  
max1 = max + 1
CFG1 = CFG \update { pred: {succ = max} | pred <- preds } \union { max : { stmts = [ break ], preds = preds, succ = [] } }  
-----------------------------------------------------------------------------------------------------------------------------
CFG, max, preds, false, contNodes, breakNodes |- continue =>  CFG1, max1, {max}, false, contNodes, breakNodes \union { max }
-}
        let max = currId st
            currNodeId = internalIdent (labPref ++ show max)
            max1 = max + 1
            cfg0 = cfg st
            preds0 = currPreds st
            s      = AST.CBlockStmt $ AST.CBreak nodeInfo
            cfgNode = Node [s] [] [] [] preds0 [] Neither
            cfg1' = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n) ++ [currNodeId]}) pred g) cfg0 preds0
            cfg1  = M.insert currNodeId cfgNode cfg1'
        in do 
          { put st{cfg = cfg1, currId=max1, currPreds=[], continuable = False, breakNodes = (breakNodes st) ++ [currNodeId] } }
    }
{-  
CFG1 = CFG \update { pred : {stmts = stmts ++ [ return exp ] } } 
--------------------------------------------------------
CFG, max, preds, true |- return exp  => CFG1, max, [] , false

max1 = max + 1
CFG1 = CFG \update { pred : {succ = max} |  pred <- preds } \union { max : {stmts = return exp } } 
--------------------------------------------------------
CFG, max, preds, false |- return exp => CFG1, max, [], false 
-}
  buildCFG (AST.CReturn mb_expression modeInfo) = do 
    { st <- get 
    ; if (continuable st) 
      then  
        let cfg0       = cfg st 
            (lhs,rhs)  = case mb_expression of { Just exp -> getVarsFromExp exp ; Nothing -> ([],[]) }
            preds0     = currPreds st
            s          = AST.CBlockStmt $ AST.CReturn mb_expression modeInfo
            cfg1       = foldl (\g pred -> M.update (\n -> Just n{stmts=(stmts n) ++ [ s ], lVars = (lVars n) ++ lhs, rVars = (rVars n) ++ rhs}) pred g) cfg0 preds0
        in do 
          { put st{cfg = cfg1, currPreds=[], continuable = False} }        
      else 
        let max        = currId st
            currNodeId = internalIdent (labPref++show max)          
            (lhs,rhs)  = case mb_expression of { Just exp -> getVarsFromExp exp ; Nothing -> ([],[]) }
            max1       = max + 1
            cfg0       = cfg st 
            preds0     = currPreds st
            s          = AST.CBlockStmt  $ AST.CReturn mb_expression modeInfo
            cfgNode    = Node [s] lhs rhs [] preds0 [] Neither
            cfg1'      = foldl (\g pred -> M.update (\n -> Just n{succs = nub $ (succs n)++[currNodeId]} ) pred g) cfg0 preds0
            cfg1       = M.insert currNodeId cfgNode cfg1'
        in do 
          {  put st{cfg = cfg1, currId=max1, currPreds=[], continuable = False} }
    }
  -- | return statement @CReturn returnExpr@
  buildCFG (AST.CAsm asmb_stmt nodeInfo) = 
    fail $ (posFromNodeInfo nodeInfo) ++  "asmbly statement not supported." 



instance CProg (AST.CCompoundBlockItem N.NodeInfo) where
  buildCFG (AST.CBlockStmt stmt) = buildCFG stmt
  buildCFG (AST.CBlockDecl decl) = buildCFG decl
  buildCFG (AST.CNestedFunDef fundec) = error "nested function not supported"
  
  
  
instance CProg (AST.CDeclaration N.NodeInfo) where
{-
CFG1 = CFG \update { pred : {stmts = stmts ++ [ty x = exp[]], lVars = lVars ++ [x] } } 
--------------------------------------------------------
CFG, max, preds, true |- ty x = exp[] => CFG1, max, [] , false 

max1 = max + 1
CFG1 = CFG \update { pred : {succ = max} |  pred <- preds } \union { max : {ty x = exp[] } } 
--------------------------------------------------------
CFG, max, preds, false |- ty x = exp[] => CFG1, max1, [], false 
-}
  buildCFG (AST.CDecl specs divs@[div] nodeInfo) = do 
    { st <- get
    ; if (continuable st) 
      then         
        let cfg0       = cfg st 
            preds0     = currPreds st
            s          = AST.CBlockDecl (AST.CDecl specs divs nodeInfo) 
            lvars      = getLHSVarsFromDecl divs -- todo
            rvars      = getRHSVarsFromDecl divs
            cfg1       = foldl (\g pred -> 
                                 M.update (\n -> Just n{ stmts=(stmts n) ++ [ s ]
                                                       , localDecls = (localDecls n) ++ lvars
                                                       , lVars = (lVars n) ++ lvars
                                                       , rVars = (rVars n) ++ rvars}) pred g) cfg0 preds0
        in do 
          { put st{cfg = cfg1} }        
      else 
        let max        = currId st
            currNodeId = internalIdent (labPref++show max)          
            max1       = max + 1
            cfg0       = cfg st 
            preds0     = currPreds st
            s          = AST.CBlockDecl (AST.CDecl specs divs nodeInfo) 
            lvars      = getLHSVarsFromDecl divs
            rvars      = getRHSVarsFromDecl divs
            cfgNode    = Node [s] lvars rvars lvars preds0 [] Neither
            cfg1'      = foldl (\g pred -> 
                                 M.update (\n -> Just n{succs = nub $ (succs n)++[currNodeId]} ) pred g) cfg0 preds0
            cfg1       = M.insert currNodeId cfgNode cfg1'
        in do 
          {  put st{cfg = cfg1, currId=max1, currPreds=[currNodeId], continuable = True} }
    }
  buildCFG (AST.CDecl specs [] nodeInfo) = return ()    
  -- breaking  int i, j; into int i; and int j;
  buildCFG (AST.CDecl specs divs nodeInfo) = 
    mapM_ buildCFG $ (map (\d -> AST.CDecl specs [d] nodeInfo) divs)
  {-
  buildCFG (AST.CStaticAssert expr str nodeInfo) = 
    fail $ (posFromNodeInfo nodeInfo) ++ "static assert decl not supported."
-}
  
-- print position info given the NodeInfo  
posFromNodeInfo :: N.NodeInfo -> String
posFromNodeInfo (N.OnlyPos pos posLen) = show pos ++ ": \n"
posFromNodeInfo (N.NodeInfo pos posLen name) = show pos ++ ": \n"



-- todo: move these to Var.hs?
-- aux functions retrieving LHS variables
getLHSVarsFromDecl :: [(Maybe (AST.CDeclarator a),  -- declarator (may be omitted)
                        Maybe (AST.CInitializer a), -- optional initialize
                        Maybe (AST.CExpression a))] -- optional size (const expr)
                      -> [Ident]
getLHSVarsFromDecl divs = 
  concatMap (\(mb_decl, mb_init, mb_ce) ->
              case mb_decl of 
                { Just (AST.CDeclr (Just ident) derivedDecl mb_strLit attrs nodeInfo) -> [ident]
                ; _                                                                   -> [] 
                }
            ) divs

getRHSVarsFromDecl :: [(Maybe (AST.CDeclarator a),  -- declarator (may be omitted)
                        Maybe (AST.CInitializer a), -- optional initialize
                        Maybe (AST.CExpression a))] -- optional size (const expr)
                      -> [Ident]
getRHSVarsFromDecl divs = 
  concatMap (\(mb_dec, mb_init, mb_ce) -> 
              case mb_init of
                { Just init -> getVarsFromInit init 
                ; Nothing   -> []
                }
            ) divs
                  

getVarsFromInit (AST.CInitExpr exp _) = let vs = getVarsFromExp exp 
                                        in fst vs ++ snd vs
getVarsFromInit (AST.CInitList ps _ ) = concatMap (\(partDesignators, init) -> (concatMap getVarsFromPartDesignator partDesignators ++ getVarsFromInit init)) ps

getVarsFromPartDesignator (AST.CArrDesig exp _ ) = let vs = getVarsFromExp exp 
                                                   in fst vs ++ snd vs
getVarsFromPartDesignator (AST.CMemberDesig id _ ) = [id]
getVarsFromPartDesignator (AST.CRangeDesig exp1 exp2 _ ) = 
  let (lvars1, rvars1) = getVarsFromExp exp1
      (lvars2, rvars2) = getVarsFromExp exp2
  in (lvars1 ++ lvars2 ++ rvars1 ++ rvars2)


getLHSVarFromExp :: AST.CExpression a -> [Ident]
getLHSVarFromExp = fst . getVarsFromExp

{-
getLHSVarFromExp (AST.CComma exps _)          = concatMap getLHSVarFromExp exps -- todo: fix me
getLHSVarFromExp (AST.CAssign op lval rval _) = getLHSVarFromExp lval
getLHSVarFromExp (AST.CVar ident _)           = [ident]
getLHSVarFromExp (AST.CIndex arr idx _ )      = getLHSVarFromExp arr
getLHSVarFromExp _                            = [] -- todo to check whether we miss any other cases
-}

getRHSVarFromExp :: AST.CExpression a -> [Ident]
getRHSVarFromExp = snd . getVarsFromExp

{-
getRHSVarFromExp (AST.CAssign op lval rval _)  = getRHSVarFromExp rval
getRHSVarFromExp (AST.CComma exps _)           = concatMap getRHSVarFromExp exps 
getRHSVarFromExp (AST.CCond e1 Nothing e3 _)   = getRHSVarFromExp e1 ++ getRHSVarFromExp e3 
getRHSVarFromExp (AST.CCond e1 (Just e2) e3 _) = getRHSVarFromExp e1 ++ getRHSVarFromExp e2 ++ getRHSVarFromExp e3 
getRHSVarFromExp (AST.CBinary op e1 e2 _)      = getRHSVarFromExp e1 ++ getRHSVarFromExp e2 
getRHSVarFromExp (AST.CCast decl e _)          = getRHSVarFromExp e
getRHSVarFromExp (AST.CUnary op e _)           = getRHSVarFromExp e
getRHSVarFromExp (AST.CSizeofExpr e _)         = getRHSVarFromExp e
getRHSVarFromExp (AST.CSizeofType decl _)      = []
getRHSVarFromExp (AST.CAlignofExpr e _ )       = getRHSVarFromExp e
getRHSVarFromExp (AST.CAlignofType decl _)     = []
getRHSVarFromExp (AST.CComplexReal e _)        = getRHSVarFromExp e
getRHSVarFromExp (AST.CComplexImag e _)        = getRHSVarFromExp e
getRHSVarFromExp (AST.CIndex arr idx _ )       = getRHSVarFromExp arr ++ getRHSVarFromExp idx
getRHSVarFromExp (AST.CCall f args _ )         = getRHSVarFromExp f ++ concatMap getRHSVarFromExp args
getRHSVarFromExp (AST.CMember e ident deref _) = getRHSVarFromExp e
getRHSVarFromExp (AST.CVar ident _)            = [ident]
getRHSVarFromExp (AST.CConst c)                = []
getRHSVarFromExp (AST.CCompoundLit decl initList _ ) = concatMap (\(partDesignators, init) -> (concatMap getVarFromPartDesignator partDesignators ++ getVarFromInit init)) initList
-- getRHSVarFromExp (AST.CGenericSelection e selector _ ) = [] -- todo c11 generic selection
getRHSVarFromExp (AST.CStatExpr stmt _ )       = [] -- todo GNU C compount statement as expr
getRHSVarFromExp (AST.CLabAddrExpr ident _ )   = [] 
getRHSVarFromExp (AST.CBuiltinExpr builtin )   = [] -- todo build in expression

-}
-- getVarFromExp :: AST.CExpression a -> [Ident]
-- getVarFromExp = getRHSVarFromExp

getVarsFromLHS :: AST.CExpression a -> ([Ident], [Ident])
getVarsFromLHS (AST.CVar ident _) = ([ident], [])
getVarsFromLHS (AST.CIndex arr idx _) =   -- require container's scalar copy, see SSA scalar copy
  let (lvars1, rvars1) = getVarsFromLHS arr
      (lvars2, rvars2) = getVarsFromExp idx -- correct!
  in (lvars1 ++ lvars2, rvars1 ++ rvars2)
getVarsFromLHS (AST.CMember strt mem _ _) = getVarsFromLHS strt -- require container's scalar copy, see SSA scalar copy
getVarsFromLHS (AST.CUnary op e _) = getVarsFromLHS e  -- require container's scalar copy, see SSA scalar copy
getVarsFromLHS e = getVarsFromExp e
  

(+*+) a b = S.toList (S.fromList (a ++ b))

-- ^ get all variable from an expression, split them into lval and rval variables
getVarsFromExp :: AST.CExpression a -> ([Ident], [Ident])
getVarsFromExp (AST.CAssign AST.CAssignOp e1 e2 _) =  
  let (lvars1, rvars1) = getVarsFromLHS e1
      (lvars2, rvars2) = getVarsFromExp e2
  in (lvars1 +*+ lvars2, rvars1 +*+ rvars2)
getVarsFromExp (AST.CAssign others_op e1 e2 _) =  -- +=, -= ...
  let (lvars1, rvars1) = getVarsFromLHS e1
      (lvars2, rvars2) = getVarsFromExp e2
      (lvars3, rvars3) = getVarsFromExp e1      
  in (lvars1 +*+ lvars2 +*+ lvars3, rvars1 +*+ rvars2 +*+ rvars3)
getVarsFromExp (AST.CComma exps _)        = 
  case unzip (map getVarsFromExp exps) of 
    { (ll, rr) -> (concat ll, concat rr) }
getVarsFromExp (AST.CCond e1 Nothing e3 _) =   
  let (lvars1, rvars1) = getVarsFromExp e1
      (lvars2, rvars2) = getVarsFromExp e3
  in (lvars1 +*+ lvars2, rvars1 +*+ rvars2)
getVarsFromExp (AST.CCond e1 (Just e2) e3 _) =   
  let (lvars1, rvars1) = getVarsFromExp e1
      (lvars2, rvars2) = getVarsFromExp e2
      (lvars3, rvars3) = getVarsFromExp e3
  in (lvars1 +*+ lvars2 +*+ lvars3, rvars1 +*+ rvars2 +*+ rvars3)
getVarsFromExp (AST.CBinary op e1 e2 _) =
  let (lvars1, rvars1) = getVarsFromExp e1
      (lvars2, rvars2) = getVarsFromExp e2
  in (lvars1 +*+ lvars2, rvars1 +*+ rvars2)
getVarsFromExp (AST.CCast decl e _)     = getVarsFromExp e
getVarsFromExp (AST.CUnary op e _)       = getVarsFromExp e
getVarsFromExp (AST.CSizeofExpr e _)     = getVarsFromExp e
getVarsFromExp (AST.CSizeofType decl _)  = ([],[])
getVarsFromExp (AST.CAlignofExpr e _ )   = getVarsFromExp e
getVarsFromExp (AST.CAlignofType decl _) = ([],[])
getVarsFromExp (AST.CComplexReal e _)    = getVarsFromExp e
getVarsFromExp (AST.CComplexImag e _)    = getVarsFromExp e
getVarsFromExp (AST.CIndex arr idx _ )   = 
  let (lvars1, rvars1) = getVarsFromExp arr
      (lvars2, rvars2) = getVarsFromExp idx
  in (lvars1 +*+ lvars2, rvars1 +*+ rvars2)
getVarsFromExp (AST.CCall f args _ ) = 
  let (lvars, rvars) = getVarsFromExp f
  in case unzip (map getVarsFromExp args) of     
    { (ll, rr) -> (concat ll +*+ lvars, concat rr +*+ rvars) }
getVarsFromExp (AST.CMember e ident _ _) = getVarsFromExp e     
getVarsFromExp (AST.CVar ident _)        = ([],[ident])
getVarsFromExp (AST.CConst c)            = ([],[])
getVarsFromExp (AST.CCompoundLit decl initList _ ) = ([], []) -- todo
getVarsFromExp (AST.CStatExpr stmt _ )       = ([],[]) -- todo GNU C compount statement as expr
getVarsFromExp (AST.CLabAddrExpr ident _ )   = ([],[]) 
getVarsFromExp (AST.CBuiltinExpr builtin )   = ([],[]) -- todo build in expression     


-- ^ insert goto statement according to the succ 
-- ^ 1. insert the else goto in if statement if it's empty
-- ^ 2. insert only the last statement is not goto
-- ^ 3. if the block ends with break or continue, replace the last statement by goto 
insertGotos :: CFG -> CFG
insertGotos cfg = 
  let containsIf :: [AST.CCompoundBlockItem N.NodeInfo] -> Bool
      containsIf items = any (\item -> case item of
                                 { (AST.CBlockStmt (AST.CIf _ _ _ _)) -> True 
                                 ; _ -> False 
                                 }) items
                         
      endsWithGoto :: [AST.CCompoundBlockItem N.NodeInfo] -> Bool 
      endsWithGoto [] = False
      endsWithGoto [AST.CBlockStmt (AST.CGoto succ _)] = True
      endsWithGoto (_:xs) = endsWithGoto xs
      

      endsWithBreak :: [AST.CCompoundBlockItem N.NodeInfo] -> Bool 
      endsWithBreak [] = False
      endsWithBreak [AST.CBlockStmt (AST.CBreak _)] = True
      endsWithBreak (_:xs) = endsWithBreak xs

      endsWithCont :: [AST.CCompoundBlockItem N.NodeInfo] -> Bool 
      endsWithCont [] = False
      endsWithCont [AST.CBlockStmt (AST.CCont _)] = True
      endsWithCont (_:xs) = endsWithCont xs

      removeLast :: [AST.CCompoundBlockItem N.NodeInfo]  -> [AST.CCompoundBlockItem N.NodeInfo] 
      removeLast [] = []
      removeLast xs = init xs

      updatePreds :: CFG -> CFG
      -- add the missing preds caused by the 'manual goto' defined by in the orig source code
      updatePreds cfg = 
        foldl (\g (l,node) ->
                let ss = stmts node
                in if endsWithGoto ss
                   then 
                     -- it has the goto from the orig src, we need to 
                     -- update the preds in the target
                     case (last ss) of 
                       { AST.CBlockStmt (AST.CGoto succ _) -> 
                            case lookupCFG succ g of 
                              { Nothing -> g
                              ; Just node' -> 
                                M.update (\n -> Just n{preds = 
                                                          if not (l `elem` (preds n)) 
                                                          then (preds n) ++ [l]
                                                          else preds n}) succ g
                              }
                       ; _ -> g
                       }
                   else g) cfg (M.toList cfg)

      insertGT :: Node -> Node 
      insertGT node | containsIf (stmts node) = case succs node of
        { s@(_:_:_) -> case stmts node of 
             { [ AST.CBlockStmt (AST.CIf e (AST.CGoto trLabel trNodeInfo) 
                                 Nothing nodeInfo) ] -> 
                  let elLabel = last s
                      stmts' = [ AST.CBlockStmt (AST.CIf e (AST.CGoto trLabel trNodeInfo) 
                                                 (Just (AST.CGoto elLabel N.undefNode)) nodeInfo) ] 
                  in node{stmts = stmts'}
             ; _ -> node
             }
        ; _ -> node }
                    | endsWithGoto (stmts node) = node
                    | endsWithBreak (stmts node) = case succs node of 
                      { [] -> node{stmts=(removeLast $ stmts node)}
                      ; (succ:_) -> 
                        let gt = AST.CBlockStmt (AST.CGoto succ N.undefNode)
                        in node{stmts=(removeLast $ stmts node) ++ [gt]}
                      }
                    | endsWithCont (stmts node) = case succs node of 
                      { [] -> node{stmts=(removeLast $ stmts node)}
                      ; (succ:_) -> 
                        let gt = AST.CBlockStmt (AST.CGoto succ N.undefNode)
                        in node{stmts=(removeLast $ stmts node) ++ [gt]}
                      }      
                    | otherwise = case succs node of
                      { [] -> -- the last node
                           node
                      ; (succ:_) -> -- should be singleton
                        let gt = AST.CBlockStmt (AST.CGoto succ N.undefNode)
                        in node{stmts=(stmts node) ++ [gt]}
                      }
  in M.map insertGT (updatePreds cfg)
     
-- ^ there are situation a phantom node (a label is mentioned in some goto or loop exit, but 
-- ^ there is no statement, hence, buildCFG will not generate such node. see\
{-
int f(int x) {
  while (1) { // 0 
    if (x < 0) { // 1
      return x; // 2
    } else { 
      x--; // 3
    }
  }
  // 4
}
-} 
-- note that 4 is phantom as succs of the failure etst of (1) at 0, which is not reachable,
-- but we need that empty node (and lambda function to be present) for the target code to be valid
insertPhantoms :: CFG -> CFG 
insertPhantoms cfg =  
  let allSuccsWithPreds :: [(Ident,Ident)] -- succ lbl and source lbl
      allSuccsWithPreds = concatMap (\(lbl,n) -> map (\succ -> (succ, lbl)) (succs n)) (M.toList cfg)
      phantomSuccsWithPreds :: M.Map Ident [Ident] -- succ lbl -> [source lbl]
      phantomSuccsWithPreds = 
        foldl (\m (succ_lbl, lbl) -> case M.lookup succ_lbl m of
                  { Nothing -> M.insert succ_lbl [lbl] m
                  ; Just _ -> M.update (\lbls -> Just (lbls ++ [lbl])) succ_lbl m
                  }) M.empty 
        (filter (\(succ_lbl,lbl) -> not (succ_lbl `M.member` cfg)) allSuccsWithPreds)
  in cfg `M.union` (M.map (\preds -> Node [] [] [] [] preds [] Neither) phantomSuccsWithPreds)

      

-- TODO:
-- I am trying to inject the formal arguments into the blk 0 as declaration so that
-- they are taken into consideration in building the SSA.
formalArgsAsDecls :: [Ident] -> CFG -> CFG
formalArgsAsDecls idents cfg = -- cfg 
  let entryLabel = iid (labPref ++ "0")
  in case M.lookup entryLabel cfg of 
    { Nothing -> cfg
    ; Just n  -> M.update (\_ -> Just n{lVars = idents ++ (lVars n)}) entryLabel cfg 
    }
