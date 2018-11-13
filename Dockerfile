# FROM codevapor/swift:5.0
FROM swift:4.2

RUN apt-get update && apt-get install -y \
	build-essential \
	libserd-dev \
	&& rm -rf /var/lib/apt/lists/*

RUN mkdir /work
WORKDIR /work

COPY Package.swift .
COPY Sources Sources
COPY Tests Tests
RUN swift build
RUN swift build -c release

EXPOSE 8080
VOLUME ["/data"]
ENV PATH="/work:/work/.build/debug:${PATH}"
ENV HDT_TEST_DATASET_PATH="/data"

CMD ["hdt-info"]
