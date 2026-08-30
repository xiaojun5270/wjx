FROM node:20-alpine

WORKDIR /app
COPY package.json server.mjs ./

ENV NODE_ENV=production
EXPOSE 8787

USER node
CMD ["node", "server.mjs"]
