#!/usr/bin/env bash

function testcmd()
{
  local pkg=$1
  shift
  local stackopts=$*

  echo "== ${pkg}"
  if stack $stackopts test $pkg; then
    echo
  else
    echo "== FAILED"
    exit 1
  fi
}

# Set the resolver. Uses the environment variable "RESOLVER" if set,
# otherwise whatever is in the "stack.yaml" file.
STACKOPTS="--no-terminal --install-ghc --resolver=$RESOLVER"
if [[ "$RESOLVER" == "" ]]; then
  STACKOPTS="--no-terminal --install-ghc"
fi

stack $STACKOPTS setup

# Make sure 'concurrency' builds.
testcmd concurrency $STACKOPTS

# Test 'dejafu'.
echo "== dejafu"
if ! stack $STACKOPTS build dejafu-tests; then
  echo "== FAILED (build)"
  exit 1
fi
if ! stack $STACKOPTS exec dejafu-tests; then
  echo "== FAILED (test)"
  exit 1
fi

# Test everything else.
for pkg in hunit-dejafu tasty-dejafu; do
  testcmd $pkg $STACKOPTS
done
