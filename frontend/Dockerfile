FROM nginx:alpine
# The official image runs envsubst on /etc/nginx/templates/*.template at startup
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY index.html style.css app.js /usr/share/nginx/html/
ENV BACKEND_URL=http://backend:4000
EXPOSE 80
