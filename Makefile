.PHONY: all build test run clean examples example

all: test

build:
	zig build

test:
	zig build test

run:
	zig build run

clean:
	rm -rf .zig-cache zig-out

examples:
	@for f in examples/*.lox; do echo "=== $$f ==="; zig build run -- "$$f"; echo; done

# Run a single example: make example F=hello
example:
	zig build run -- examples/$(F).lox
