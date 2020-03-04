{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-} 
module Examples.ExampleChecker where

import Types.Program
import Types.Type
import Types.Environment
import Types.Experiments
import Types.IOFormat
import Types.TypeChecker
import Synquid.Type
import Synquid.Pretty
import Synquid.Logic
import HooglePlus.TypeChecker
import PetriNet.Util

import Bag
import Control.Exception
import Control.Monad.State
import Control.Lens
import Control.Concurrent.Chan
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Char
import Data.Either
import Data.Maybe
import Data.List
import GHC
import GHCi hiding(Message)
import GHCi.RemoteTypes
import GHC.Paths
import TcRnDriver
import Debugger
import Exception
import HsUtils
import HsTypes
import Outputable
import Text.Printf

parseExample :: [String] -> Example -> IO (Either RSchema ErrorMessage)
parseExample mdls ex = catch (do
    typ <- runGhc (Just libdir) $ do
        dflags <- getSessionDynFlags
        setSessionDynFlags dflags
        prepareModules mdls >>= setContext
        exprType TM_Default mkFun
    let hsType = typeToLHsType typ
    return (Left $ resolveType hsType))
    (\(e :: SomeException) -> return (Right $ show e))
    where
        mkFun = printf "\\f -> f %s == %s" (unwords $ inputs ex) (output ex)

resolveType :: LHsType GhcPs -> RSchema
resolveType (L _ (HsForAllTy bs t)) = foldr ForallT (resolveType t) vs
    where
        vs = map vname bs
        vname (L _ (UserTyVar (L _ id))) = showSDocUnsafe (ppr id)
        vname (L _ (KindedTyVar (L _ id) _)) = showSDocUnsafe (ppr id)
resolveType (L _ (HsFunTy f _)) = Monotype (resolveType' f)
resolveType t = error (showSDocUnsafe $ ppr t)

resolveType' :: LHsType GhcPs -> RType
resolveType' (L _ (HsFunTy f r)) = FunctionT "" (resolveType' f) (resolveType' r)
resolveType' (L _ (HsQualTy _ t)) = resolveType' t
resolveType' (L _ (HsTyVar _ (L _ v))) = 
    if isLower (head name)
       then ScalarT (TypeVarT Map.empty name) ftrue
       else ScalarT (DatatypeT name [] []) ftrue
    where
        name = showSDocUnsafe $ ppr v
resolveType' t@(L _ HsAppTy{}) = ScalarT (DatatypeT dtName dtArgs []) ftrue
    where
        dtName = case datatypeOf t of
                   "[]" -> "List"
                   "(,)" -> "Pair"
                   n -> n
        dtArgs = datatypeArgs t

        datatypeOf (L _ (HsAppTy f _)) = datatypeOf f
        datatypeOf (L _ (HsTyVar _ (L _ v))) = showSDocUnsafe (ppr v)

        datatypeArgs (L _ (HsAppTy (L _ HsTyVar {}) a)) = [resolveType' a]
        datatypeArgs (L _ (HsAppTy f a)) = datatypeArgs f ++ datatypeArgs a
        datatypeArgs t = [resolveType' t]

resolveType' (L _ (HsListTy t)) = ScalarT (DatatypeT "List" [resolveType' t] []) ftrue
resolveType' (L _ (HsTupleTy _ ts)) = foldr mkPair basePair otherTyps
    where
        mkPair acc t = ScalarT (DatatypeT "Pair" [acc, t] []) ftrue
        resolveTyps = map resolveType' ts
        (baseTyps, otherTyps) = splitAt (length ts - 2) resolveTyps
        basePair = ScalarT (DatatypeT "Pair" baseTyps []) ftrue
resolveType' (L _ (HsParTy t)) = resolveType' t
resolveType' t = error $ showSDocUnsafe (ppr t)

checkExample :: Environment -> RSchema -> Example -> Chan Message -> IO (Either Example ErrorMessage)
checkExample env typ ex checkerChan = do
    eitherTyp <- parseExample (Set.toList $ env ^. included_modules) ex
    case eitherTyp of
      Left exTyp -> do
        let err = printf "%s does not have type %s" (show ex) (show typ) :: String
        res <- checkTypes env checkerChan exTyp typ 
        if res then return $ Left ex 
               else return $ Right err
      Right e -> return $ Right e

checkExamples :: Environment -> RSchema -> [Example] -> Chan Message -> IO (Either [Example] [ErrorMessage])
checkExamples env typ exs checkerChan = do
    outExs <- mapM (\ex -> checkExample env typ ex checkerChan) exs
    let (validResults, errs) = partitionEithers outExs
    if null errs then return $ Left validResults
                 else return $ Right errs

execExample :: [String] -> Environment -> String -> Example -> IO (Either ErrorMessage String)
execExample mdls env prog ex =
    runGhc (Just libdir) $ do
        dflags <- getSessionDynFlags
        setSessionDynFlags dflags
        prepareModules mdls >>= setContext
        let prependArg = unwords (Map.keys $ env ^. arguments)
        let progBody = if Map.null (env ^. arguments) -- if this is a request from front end
            then printf "let f = %s in" prog
            else printf "let f = \\%s -> %s in" prependArg prog
        let wrapParens x = printf "(%s)" x
        let progCall = printf "f %s" (unwords (map wrapParens $ inputs ex))
        result <- execStmt (unwords [progBody, progCall]) execOptions
        case result of
            ExecComplete r _ -> case r of
                                  Left e -> liftIO (print e) >> return (Left (show e)) 
                                  Right ns -> getExecValue ns
            ExecBreak {} -> return (Left "error, break")
    where
        getExecValue (n:ns) = do
            df <- getSessionDynFlags
            mty <- lookupName n
            case mty of
                Just (AnId aid) -> do
                    t <- gtry $ obtainTermFromId maxBound True aid
                    case t of
                        Right term -> showTerm term >>= return . Right . showSDocUnsafe
                        Left (exn :: SomeException) -> return (Left $ show exn)
                _ -> return (Left "Unknown error")
        getExecValue [] = return (Left "Empty result list")

-- to check two type are exactly the same
-- what about swapping arg orders?
augmentTestSet :: Environment -> RSchema -> IO [Example]
augmentTestSet env goal = do
    let candidates = env ^. queryCandidates
    msgChan <- newChan
    matchCands <- filterM (\s -> checkTypes env msgChan s goal) (Map.keys candidates)
    let usefulExs = concatMap (\s -> candidates Map.! s) matchCands
    return $ nubBy (\x y -> inputs x == inputs y) usefulExs

checkExampleOutput :: [String] -> Environment -> String -> [Example] -> IO (Maybe [Example])
checkExampleOutput mdls env prog exs = do
    currOutputs <- mapM (execExample mdls env prog) exs
    let cmpResults = map (uncurry compareResults) (zip currOutputs exs)
    let justResults = catMaybes cmpResults
    if length justResults == length exs then return $ Just justResults 
                                        else return Nothing
    where
        compareResults currOutput ex
          | output ex == "??" = Just (ex { output = either id id currOutput })
          | otherwise = case currOutput of
                          Left e -> Nothing
                          Right o | o == output ex -> Just ex
                                  | otherwise -> Nothing

prepareModules mdls = do
    let imports = map (printf "import %s") mdls
    decls <- mapM parseImportDecl imports
    return (map IIDecl decls)

checkTypes :: Environment -> Chan Message -> RSchema -> RSchema -> IO Bool
checkTypes env checkerChan s1 s2 = do
    let initChecker = emptyChecker { _checkerChan = checkerChan }
    state <- execStateT (do
        s1' <- freshType s1
        s2' <- freshType s2
        solveTypeConstraint env (shape s1') (shape s2')) initChecker
    return $ state ^. isChecked