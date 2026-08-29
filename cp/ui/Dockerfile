FROM node:22-alpine AS build

WORKDIR /app
COPY package.json yarn.lock .yarnrc.yml ./
RUN corepack enable && yarn install --immutable
COPY . .
RUN yarn build

FROM joseluisq/static-web-server:2-alpine

COPY --from=build /app/dist /public
ENV SERVER_ROOT=/public \
    SERVER_FALLBACK_PAGE=index.html
EXPOSE 80
