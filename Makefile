.PHONY: setup setup-android build test android test-android deploy
setup:
	./scripts/setup-dev.sh
setup-android:
	./scripts/setup-android.sh
build:
	./scripts/dev dune build @all
test:
	./scripts/dev dune runtest
android:
	./scripts/build-android.sh
test-android:
	./scripts/test-android.sh $(or $(SSH_TARGET),asko-phone)
deploy:
	./scripts/deploy-android.sh $(or $(SSH_TARGET),asko-phone)
