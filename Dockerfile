# setup build arguments for version of dependencies to use
ARG DOCKER_GEN_VERSION=0.10.2
ARG FOREGO_VERSION=v0.17.0

# Use a specific version of golang to build both binaries
FROM golang:1.20.2 as gobuilder

# Build docker-gen from scratch
FROM gobuilder as dockergen

ARG DOCKER_GEN_VERSION

RUN git clone https://github.com/nginx-proxy/docker-gen \
   && cd /go/docker-gen \
   && git -c advice.detachedHead=false checkout $DOCKER_GEN_VERSION \
   && go mod download \
   && CGO_ENABLED=0 GOOS=linux go build -ldflags "-X main.buildVersion=${DOCKER_GEN_VERSION}" ./cmd/docker-gen \
   && go clean -cache \
   && mv docker-gen /usr/local/bin/ \
   && cd - \
   && rm -rf /go/docker-gen

# Build forego from scratch
FROM gobuilder as forego

ARG FOREGO_VERSION

RUN git clone https://github.com/nginx-proxy/forego/ \
   && cd /go/forego \
   && git -c advice.detachedHead=false checkout $FOREGO_VERSION \
   && go mod download \
   && CGO_ENABLED=0 GOOS=linux go build -o forego . \
   && go clean -cache \
   && mv forego /usr/local/bin/ \
   && cd - \
   && rm -rf /go/forego

# Build the final image
FROM nginx:1.23.3 as modsecbuild

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
RUN wget http://nginx.org/download/nginx-1.23.3.tar.gz
RUN tar xf nginx-nginx:1.23.3.tar.gz
WORKDIR nginx-1.23.3
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
FROM nginx:1.23.3

ARG NGINX_PROXY_VERSION
# Add DOCKER_GEN_VERSION environment variable
# Because some external projects rely on it
ARG DOCKER_GEN_VERSION
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_VERSION} \
   DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
   DOCKER_HOST=unix:///tmp/docker.sock

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
    libfuzzy2 liblua5.3 zlib1g vim \
 && wget -P /etc/nginx/modsec/ https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended \
 && mv /etc/nginx/modsec/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf \
 && sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf \
 && sed -iE '/\/var\/run\/nginx.pid;/a load_module modules/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf \
 && mkdir /etc/nginx/modsec/crs && cd /etc/nginx/modsec/crs \
 && cd /etc/nginx/modsec/crs && curl -L https://github.com/coreruleset/coreruleset/archive/refs/tags/v3.3.0.tar.gz | tar --strip-components 1 -xz \
 && for src in $(find * -name "*.example"); do dst=$(echo $src|cut -f 1-2 -d '.'); mv $src $dst; done \
 && apt-get clean \
 && rm -r /var/lib/apt/lists/*

# add modsec conf
ADD modsec_main.conf /etc/nginx/modsec/main.conf

# Configure Nginx
RUN echo "daemon off;" >> /etc/nginx/nginx.conf \
   && sed -i 's/worker_processes  1/worker_processes  auto/' /etc/nginx/nginx.conf \
   && sed -i 's/worker_connections  1024/worker_connections  10240/' /etc/nginx/nginx.conf \
   && mkdir -p '/etc/nginx/dhparam'

# Install Forego + docker-gen
COPY --from=forego /usr/local/bin/forego /usr/local/bin/forego
COPY --from=dockergen /usr/local/bin/docker-gen /usr/local/bin/docker-gen

COPY network_internal.conf /etc/nginx/

COPY app nginx.tmpl LICENSE /app/
WORKDIR /app/

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["forego", "start", "-r"]
