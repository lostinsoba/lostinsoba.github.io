prepare:
	CGO_ENABLED=1 go install --tags extended github.com/gohugoio/hugo@v0.111.3
	 git submodule update --init --recursive

develop:
	hugo server

build:
	hugo
