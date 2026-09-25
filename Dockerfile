FROM fluent/fluentd:v1.16-debian
USER root
RUN gem install fluent-plugin-elasticsearch -v 5.3.0
USER fluent

