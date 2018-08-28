###############################
# Stage wkhtmltopdf
FROM madnight/docker-alpine-wkhtmltopdf as wkhtmltopdf

######################
# Stage: ruby
FROM ruby:2.5.1-alpine3.7 as ruby
LABEL description="Base ruby image used by other stages"



######################
# Stage: bundler
FROM ruby as bundler
LABEL description="Install and cache gems for all environments"

WORKDIR /home/app

# Copy the Gemfile and Gemfile.lock
COPY Gemfile* /home/app/

# Install build deps as virtual dependencies.
#
# - build-base -- used to install gcc, make, etc.
# - libxml2-dev -- used to install nokogiri native extension
# - libxslt-dev -- used to install nokogiri native extension
RUN apk add --update --no-cache --virtual .build-deps \
   build-base \
   libxml2-dev \
   libxslt-dev \
 && bundle config build.nokogiri --use-system-libraries \
 && bundle install --frozen --deployment --jobs 4 --retry 3 \
 # Remove unneeded files (*/.git, *.o, *.c) but keeps cached gems for later stages
 && find vendor/bundle/ -name ".git" -exec rm -rv {} + \
 && find vendor/bundle/ -name "*.c" -delete \
 && find vendor/bundle/ -name "*.o" -delete \
 && rm -rf vendor/bundle/ruby/*/cache \
 # Remove unneeded build deps
 && apk del .build-deps



###############################
# Stage runner
FROM ruby as runner
LABEL description="Builds an image ready to be run"

# Install runtime deps and create non-root user.
#
# If you need to install specific libraries for test environment
# please use a virtual pkg holder you can easily remove on the
# `release` stage.
#
# For example:
#   RUN apk add --update --no-cache --virtual .test-deps \
#     somelib-only-used-for-test
# Then in the `release` image:
#   RUN apk del .test-deps
#
# - glib -- runtime deps for wkhtmltopdf
# - libcrypto1.0 -- runtime deps for wkhtmltopdf
# - libgcc -- runtime deps for wkhtmltopdf
# - libintl -- runtime deps for wkhtmltopdf
# - libssl1.0 -- runtime deps for wkhtmltopdf
# - libstdc++ -- runtime deps for wkhtmltopdf
# - libx11 -- runtime deps for wkhtmltopdf
# - libxext -- runtime deps for wkhtmltopdf
# - libxml2 -- used to run nokogiri
# - libxrender -- runtime deps for wkhtmltopdf
# - libxslt -- used to run nokogiri
# - nodejs -- used to compile assets
# - ttf-dejavu ttf-droid ttf-freefont ttf-liberation ttf-ubuntu-font-family -- runtime deps for wkhtmltopdf
# - tzdata -- used to install TZinfo data
RUN apk add --update --no-cache \
    glib \
    libcrypto1.0 \
    libgcc \
    libintl \
    libssl1.0 \
    libstdc++ \
    libx11 \
    libxext \
    libxml2 \
    libxrender \
    libxslt \
    nodejs \
    ttf-dejavu ttf-droid ttf-freefont ttf-liberation ttf-ubuntu-font-family \
    tzdata \
 && addgroup -g 1000 -S app \
 && adduser -u 1000 -S app -G app

USER app
WORKDIR /home/app

# Copy wkhtmltopdf bin from wkhtmltopdf stage
COPY --from=wkhtmltopdf /bin/wkhtmltopdf /usr/bin/
# Copy bundle config from bundler stage
COPY --chown=app:app --from=bundler /usr/local/bundle/config /usr/local/bundle/config
# Copy bundled gems from bundler stage
COPY --chown=app:app --from=bundler /home/app/vendor /home/app/vendor
# Copy source files according to .dockerignore policy
# Make sure your .dockerignore file is properly configure to ensure proper layer caching
COPY --chown=app:app . /home/app

ENV PORT 3000

# Expose web server port
EXPOSE 3000
ENTRYPOINT ["bundle", "exec"]

CMD ["puma", "-C", "config/puma.rb"]



###############################
# Stage compiler
FROM runner as compiler
LABEL description="Builds a compiler image used to compile assets"

# Copy cached compiled assets to avoid re-compiling them
# We use latest compiler image to get already compiled assets
# and save lots of time on assets compilation for this new image
COPY --chown=app:app --from=my-app:compiler /home/app/public /home/app/public
COPY --chown=app:app --from=my-app:compiler /home/app/tmp /home/app/tmp

# Env variables required to run rake assets:precompile
ARG ASSET_HOST
ARG ENV=production

# Precompile assets and keep the cache for future releases
RUN ASSET_HOST=$ASSET_HOST \
    RAILS_ENV=$ENV \
    bundle exec rake assets:precompile



###############################
# Stage release
FROM runner as release
LABEL description="Builds a release image removing unneeded files and dependencies"

# Removes development and test gems by re-running the bundle
# install command using cached gems and simply removing unneeded
# gems using the clean option.
RUN bundle install --local --clean --without development test \
 # Remove unneeded cached gems
 && find vendor/bundle/ -name "*.gem" -delete \
 # Remove unneeded files and folders
 && rm -rf spec tmp/cache node_modules app/assets vendor/assets lib/assets

# Copy compiled assets
COPY --chown=app:app --from=compiler /home/app/public /home/app/public

ARG ASSET_HOST
ARG ENV=production

# Set App env variables
ENV ASSET_HOST $ASSET_HOST
ENV RAILS_ENV $ENV
