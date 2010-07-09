
all: build

build:
	erl -make

run_prereqs: all

test: run_prereqs
	$(ERL_CMD) -noshell -pa ../mochiweb/ebin -s openid_srv test -s init stop

clean: cleanlog
	rm -f ebin/*.beam

cleanlog:
	rm -f auth.log report.log sasl_err.log
	rm -f *.access

