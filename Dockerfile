# 1. Base Image
FROM dart:stable AS build
WORKDIR /app

# 2. Install dart_frog_cli
RUN dart pub global activate dart_frog_cli

# 3. Resolve app dependencies
COPY pubspec.* ./
RUN dart pub get

# 4. Copy app source code
COPY . .

# 5. Build the production version (creates a /build folder)
RUN dart pub global run dart_frog_cli:dart_frog build

# 6. Compile the generated server Dart code to an executable
WORKDIR /app/build
RUN dart compile exe bin/server.dart -o /app/bin/server

# 7. Final minimal serving image layer
# Using debian instead of 'scratch' so we have SSL certificates (needed for Gemini API)
FROM debian:stable-slim

# Install latest SSL Certificates for HTTPS calls to Google AI Studio
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy runtime from dart image
COPY --from=build /runtime/ /
# Copy compiled executable
COPY --from=build /app/bin/server /app/bin/

# Set env and start the server
ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/server"]
