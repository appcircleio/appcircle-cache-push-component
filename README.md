# Appcircle Cache Push

Uploads user selected files and folders to Appcircle cache.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_CACHE_INCLUDED_PATHS`: Specifies the files and folder which should be in cache. Multiple glob patterns can be defined with colon seperated. For example; .gradle:app/build
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.

Optional Input Variables

- `AC_CACHE_EXCLUDED_PATHS`: Specifies the files and folder which should be ignored from cache. Multiple glob patterns can be defined with colon seperated. For example; .gradle/*.lock:*.apk
- `AC_REPOSITORY_DIR`: Cloned git repository path. Included and excluded paths are defined relative to cloned repository, except `~` prefixed paths.
