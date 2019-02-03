#!/bin/bash

if [[ ! -z $1 ]]; then
    cp libraries/$1 /tmp/base.txt
fi

stack exec -- synquid generate \
      -p base \
      -m "Data.Word" \
      -m "Data.Int" \
      -m "Data.Maybe" \
      -m "Data.ByteString.Builder" \
      -m "Data.ByteString.Lazy" \
      -m "Data.Map.Strict" \
      -m "Data.List" \
      -m "Data.Tuple" \
      -m "GHC.List" \
      -m "GHC.Char" \
      -m "Data.ByteString" \
      -m "Data.Set"
