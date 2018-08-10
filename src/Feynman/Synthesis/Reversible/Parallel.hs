module Feynman.Synthesis.Reversible.Parallel where

import Feynman.Core
import Feynman.Algebra.Base
import Feynman.Algebra.Linear
import Feynman.Algebra.Matroid
import Feynman.Synthesis.Phase
import Feynman.Synthesis.Reversible

import Data.Map.Strict (Map, (!))
import qualified Data.Map.Strict as Map

import Data.Set (Set)
import qualified Data.Set as Set

import Control.Monad.State.Strict
import Control.Monad.Writer.Lazy

-- The Matroid from the t-par paper [AMM2014]
instance Matroid (Phase, Int) where
  independent s
    | Set.null s = True
    | otherwise  =
      let ((v, _), n) = head $ Set.toList s
          (vecs, exps) = unzip $ fst $ unzip $ Set.toList s
      in
      (all ((8 <=) . order) exps || all ((8 >) . order) exps)
      && width v - rank (fromList vecs) <= n - (length vecs)

tpar :: Synthesizer
tpar input output [] may = (linearSynth input output, may)
tpar input output xs may =
  let partition      = partitionAll (zip xs $ repeat $ length input)
      (circ, input') = foldr synthPartition ([], input) partition
  in
    (circ ++ linearSynth input' output, may)

synthPartition set (circ, input) =
  let (ids, ivecs) = unzip $ Map.toList input
      (vecs, exps) = unzip $ fst $ unzip $ Set.toList set
      inp     = fromList ivecs
      targ    = resizeMat (m inp) (n inp) . (flip fillFrom $ inp) . fromList $ vecs
      output  = Map.fromList (zip ids $ toList targ)
      g (n,i) = synthesizePhase (ids!!i) n
      perm    = linearSynth input output
      phase   = concatMap g (zip exps [0..])
  in
    (circ++perm++phase, output)

tparMore input output xs may = tpar input output xs' may
  where xs' = filter (\(bv, i) -> order i /= 1 && wt bv /= 0) xs
