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
RUN dart pub get
RUN dart compile exe bin/server.dart -o bin/server

# 7. Final minimal serving image layer
# Using 'scratch' (empty image) because dart:stable provides all needed system files, 
# including SSL certificates for Gemini, in its /runtime folder!
FROM scratch

# Copy the Dart runtime and required configuration files
COPY --from=build /runtime/ /

# Copy the compiled Dart executable
COPY --from=build /app/build/bin/server /app/bin/

# Set env and start the server
ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/server"]
