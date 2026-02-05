.PHONY: all test run

all: test

test:
	zig build test

build:
	zig build
