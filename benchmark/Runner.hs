module Runner where

import BTypes
import BConfig
import Types.Program
import Types.Environment
import Types.Experiments
import Synquid.Util
import HooglePlus.Synthesize
import Database.Environment

import System.Timeout
import Control.Concurrent.Chan
import Control.Concurrent.ParallelIO.Local
import qualified Data.Map as Map
import Data.Maybe
import Data.Either
import GHC.Conc (getNumCapabilities)


runExperiments :: [Experiment] -> IO [ResultSummary]
runExperiments exps = do
  maxThreads <- getNumCapabilities
  mbResults <- withPool (maxThreads - 1) (runPool exps) -- Leave one core for OS/other jobs
  return $ catMaybes $ map summarizeResult (zip exps mbResults)

runPool :: [Experiment] -> Pool -> IO [Maybe [(RProgram, TimeStatistics)]]
runPool exps pool = do
  rights <$> parallelE pool (listOfExpsToDo exps)
  where
    listOfExpsToDo :: [Experiment] -> [IO (Maybe [(RProgram, TimeStatistics)])]
    listOfExpsToDo = map runExperiment

runExperiment :: Experiment -> IO (Maybe [(RProgram, TimeStatistics)])
runExperiment (env, envName, q, params, paramName) = do
  let queryStr = query q
  goal <- envToGoal env queryStr
  timeout defaultTimeoutus $ synthesize params goal

summarizeResult :: (Experiment, Maybe [(RProgram, TimeStatistics)]) -> Maybe ResultSummary
summarizeResult (_, Nothing) = Nothing
summarizeResult ((_, envN, q, _, paramN), Just results) = Just ResultSummary {
  envName = envN,
  paramName = paramN,
  queryName = name q,
  queryStr = query q,
  solution = soln,
  tFirstSoln = totalTime firstR,
  tEncFirstSoln = encodingTime firstR,
  lenFirstSoln = pathLength firstR,
  refinementSteps = iterations firstR,
  transitions = safeTransitions
  }
  where
    safeTransitions = snd $ errorhead "missing transitions" $ (Map.toDescList (numOfTransitions firstR))
    soln = mkOneLine (show solnProg)
    (solnProg, firstR) =  errorhead "missing first solution" results
    errorhead msg xs = fromMaybe (error msg) $ listToMaybe xs