# setup build arguments for version of dependencies to use
ARG DOCKER_GEN_VERSION=0.7.6
ARG FOREGO_VERSION=0.16.1

# Use a specific version of golang to build both binaries
FROM golang:1.15.10 as gobuilder

# Build docker-gen from scratch
FROM gobuilder as dockergen

ARG DOCKER_GEN_VERSION

RUN git clone https://github.com/jwilder/docker-gen \
   && cd /go/docker-gen \
   && git -c advice.detachedHead=false checkout $DOCKER_GEN_VERSION \
   && go mod download \
   && CGO_ENABLED=0 GOOS=linux go build -ldflags "-X main.buildVersion=${DOCKER_GEN_VERSION}" ./cmd/docker-gen \
   && go clean -cache \
   && mv docker-gen /usr/local/bin/ \
   && cd - \
   && rm -rf /go/docker-gen

# Build forego from scratch
# Because this relies on golang workspaces, we need to use go < 1.8. 
FROM gobuilder as forego

# Download the sources for the given version
ARG FOREGO_VERSION
ADD https://github.com/jwilder/forego/archive/v${FOREGO_VERSION}.tar.gz sources.tar.gz

# Move the sources into the right directory
RUN tar -xzf sources.tar.gz && \
   mkdir -p /go/src/github.com/ddollar/ && \
   mv forego-* /go/src/github.com/ddollar/forego

# Install the dependencies and make the forego executable
WORKDIR /go/src/github.com/ddollar/forego/
RUN go get -v ./... && \
   CGO_ENABLED=0 GOOS=linux go build -o forego .

# Build the final image
FROM nginx:1.19.10 as modsecbuild

# Install wget and install/updates certificates
RUN apt-get update \
 && apt-get install -y -q --no-install-recommends \
    ca-certificates \
    wget
# Build modsecurity nginx module
RUN apt update \
    && apt install --no-install-recommends -y \
       git \
       make \
       build-essential automake
RUN git clone https://github.com/SpiderLabs/ModSecurity.git
RUN apt install -y --no-install-recommends libtool libyajl-dev \
    libgeoip-dev libtool dh-autoreconf libcurl4-gnutls-dev libxml2 libpcre++-dev \
    libxml2-dev liblmdb-dev \
    libfuzzy-dev g++ flex bison curl doxygen 
RUN apt install -y --no-install-recommends pkgconf liblua5.3-dev
WORKDIR /ModSecurity
RUN git checkout ${MODSECURITY_VERSION}
RUN git submodule init
RUN git submodule update
RUN ./build.sh
RUN ./configure
RUN make -j4
RUN make install
WORKDIR /
RUN apt-get install -y --no-install-recommends zlib1g-dev procps
RUN git clone --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git
RUN wget http://nginx.org/download/nginx-1.19.10.tar.gz
RUN tar xf nginx-1.19.10.tar.gz
WORKDIR nginx-1.19.10
RUN ./configure --with-compat --add-dynamic-module=../ModSecurity-nginx
RUN make modules
RUN cp objs/ngx_http_modsecurity_module.so /etc/nginx/modules
RUN mkdir /etc/nginx/modsec \
 && wget -P /etc/nginx/modsec/ https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended \
 && mv /etc/nginx/modsec/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf \
 && cp /ModSecurity/unicode.mapping /etc/nginx/modsec \
 && sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf \
 && sed -iE '/\/var\/run\/nginx.pid;/a load_module modules/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf
ADD modsec_main.conf /etc/nginx/modsec/main.conf
RUN apt-get clean \
 && rm -r /var/lib/apt/lists/*

# Build the final image
FROM nginx:1.19.10
LABEL maintainer="Andreas Elvers <andreas.elvers@lfda.de> (@buchdag)"

# copy modsec build

COPY --from=modsecbuild /nginx-1.19.10/objs/ngx_http_modsecurity_module.so /etc/nginx/modules/
COPY --from=modsecbuild /ModSecurity/unicode.mapping /etc/nginx/modsec/unicode.mapping
COPY --from=modsecbuild /usr/local/modsecurity/lib/libmodsecurity.so.3 /usr/local/modsecurity/lib/libmodsecurity.so.3

# Install dependencies

RUN apt-get update \
 && apt-get install -y -q --no-install-recommends \
    ca-certificates \
    wget libyajl2 libgeoip1 libcurl3-gnutls libxml2 libpcre++ libxml2 liblmdb0 \
    libfuzzy2 liblua5.3 zlib1g \
 && wget -P /etc/nginx/modsec/ https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended \
 && mv /etc/nginx/modsec/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf \
 && sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf \
 && sed -iE '/\/var\/run\/nginx.pid;/a load_module modules/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf \
 && apt-get clean \
 && rm -r /var/lib/apt/lists/*

# add modsec conf
ADD modsec_main.conf /etc/nginx/modsec/main.conf

# Configure Nginx and apply fix for very long server names
RUN echo "daemon off;" >> /etc/nginx/nginx.conf \
 && sed -i 's/worker_processes  1/worker_processes  auto/' /etc/nginx/nginx.conf \
 && sed -i 's/worker_connections  1024/worker_connections  10240/' /etc/nginx/nginx.conf

# Install Forego + docker-gen
COPY --from=forego /go/src/github.com/ddollar/forego/forego /usr/local/bin/forego
COPY --from=dockergen /usr/local/bin/docker-gen /usr/local/bin/docker-gen

# Add DOCKER_GEN_VERSION environment variable
# Because some external projects rely on it
ARG DOCKER_GEN_VERSION
ENV DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION}

COPY network_internal.conf /etc/nginx/

COPY . /app/
WORKDIR /app/

ENV DOCKER_HOST unix:///tmp/docker.sock

VOLUME ["/etc/nginx/certs", "/etc/nginx/dhparam"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["forego", "start", "-r"]
