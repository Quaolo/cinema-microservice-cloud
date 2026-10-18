FROM node:24-alpine

RUN apk add --no-cache dumb-init

WORKDIR /home/node/app

COPY package.json package-lock.json ./

RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY src/ ./src

USER node

EXPOSE 3003

CMD ["dumb-init", "node", "src/index.js"]
