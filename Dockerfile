# Serves the prebuilt React SPA (`npm run build` output in build/) on port 8080.
# The app is NOT built here: the build needs src/aws-exports.js, which only
# exists after `amplify push`, so CodeBuild runs `npm run build` first.
# Exact tag, never latest/stable. public.ecr.aws avoids Docker Hub rate limits.
FROM public.ecr.aws/nginx/nginx-unprivileged:1.29.3-alpine
COPY deployment/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY build/ /usr/share/nginx/html/

# The task runs with a read-only root filesystem and mounts empty volumes at
# /tmp (pid file, client/proxy temp dirs) and /var/cache/nginx. On Fargate an
# empty bind-mount volume is root-owned 0755, so nginx (uid 101) cannot write
# to it. ECS copies a path's contents AND ownership into the volume only when
# the image declares a VOLUME at the same containerPath, so declare both here
# with nginx-owned directories.
USER root
RUN chown 101:101 /tmp /var/cache/nginx && chmod 1777 /tmp
USER 101
VOLUME ["/tmp", "/var/cache/nginx"]

EXPOSE 8080
