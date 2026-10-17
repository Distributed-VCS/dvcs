#!/usr/bin/env bash
# Entrypoint for the DVCS Docker image. Dispatches on the first argument:
#
#   demo               (default) run the automated tutorial demo
#   shell              drop into an interactive shell with dvcs on PATH,
#                      everything already built -- explore manually
#   test               run the unit test suite (v test .)
#   integration-test   run the full integration test suite
#
# Anything else is executed as-is (so `docker run <image> dvcs help` also
# works, for example).
set -e
cd /app

case "${1:-demo}" in
demo)
	shift || true
	exec ./scripts/demo.sh "$@"
	;;
shell)
	exec bash
	;;
test)
	cd cli
	exec v -cc tcc test .
	;;
integration-test)
	exec ./test/integration/run.sh
	;;
*)
	exec "$@"
	;;
esac
