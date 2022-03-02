# Appcircle Cache Push

Uploads user selected files and folders to Appcircle cache.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_CACHE_INCLUDED_PATHS`: Specifies the files and folders which should be in cache. Multiple glob patterns can be provided as a colon-separated list. For example; .gradle:app/build
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.
- `ASPNETCORE_CALLBACK_URL`: System generated callback url for signed url web service. It's different for various environments.

Optional Input Variables

- `AC_CACHE_EXCLUDED_PATHS`: Specifies the files and folders which should be ignored from cache. Multiple glob patterns can be provided as a colon-separated list. For example; .gradle/*.lock:*.apk
- `AC_REPOSITORY_DIR`: Cloned git repository path. Included and excluded paths are defined relative to cloned repository, except `~/`, `/` or environment variable prefixed paths. See following sections for more details.

## Included & Excluded Paths

Cache step uses a pattern in order to select files and folders. That the pattern is not a regexp, it's closer to a shell glob. (_The verb "glob" is an old Unix term for filename matching in a shell._)

Also we have some keywords or characters for special use cases, especially for system folders. Following sections summarize cache step's supported patterns for included and excluded paths.

### System vs. Repository

In order to identify between a repository resource and a system resource, cache step checks prefix for each given pattern.

Resource word, used in the document, means files or folders in this context.

Repository resources begin with directly glob pattern. They shouldn't be prefixed with `/` or other folder tree characters.

For example:

- `.gradle/` is .gradle folder in project repository.
- `local.properties` is single file in project repository.
- `*.apk` is related with .apk files in project repository.

Repository resources are generated with git clone on most cases. For this reason, take care of step order while using cache and git clone for repository reources.

On the other hand system resources for `$HOME` begin with `~/` pattern. These resources are generated on build and on most cases they're not included in repository.

For example:

- `~/.gradle/` is .gradle folder at $HOME.
- `~/Library/Caches/CocoaPods` is Cocoapods caches folder at $HOME.

 Also other system-wide resources are reachable with prefix `/`.

---

**Note:** We should be careful with dynamic folder paths which are temporary on builds.

From build to build, their absolute path is changing. For example, `_appcircle_temp` folder's absolute path is `/Volumes/agent-disk/agent/workflow_data/xjr1walp.ikh/_appcircle_temp` on one build and is `/Volumes/agent-disk/agent/workflow_data/y3jdjln4.0kj/_appcircle_temp` on another build.

So, for those kinds of resources, we should prefix include and exclude paths with Appcircle-specific (reserved) environment variables.

For example:

- `$AC_TEMP_DIR/appcircle_build_ios_simulator/SimulatorDerivedData` is simulator derived data resources at `_appcircle_temp`.

See full list of environment variables at [Appcircle docs](https://docs.appcircle.io/environment-variables/appcircle-specific-environment-variables/).

---

### Glob Patterns

#### `*`

Match zero or more characters. A glob consisting of only the asterisk and no other characters or wildcards will match all files or folders in that folder.

Examples:

- `AC_CACHE_INCLUDED_PATHS=*`: All files and folders in repository included.

We can also focus into subfolders with prefixing parent folders relative to repository.

- `AC_CACHE_INCLUDED_PATHS=app/*`: All files and folders in "app" folder included.

The asterisk is usually combined with a file extension and other characters for prefix or instring matches. See examples below:

- `AC_CACHE_INCLUDED_PATHS=*.properties`: All files with .properties extension in repository root. (_no subfolders included_)
- `AC_CACHE_INCLUDED_PATHS=gradle*`: All files and folders begin with "gradle" in repository root. (_no subfolders included_)
- `AC_CACHE_INCLUDED_PATHS=*release*`: All files and folders begin with "gradle" in repository root. (_no subfolders included_)

We can also focus them into subfolders with prefixing parent folders relative to repository.

- `AC_CACHE_INCLUDED_PATHS=app/*.properties`: All files with .properties extension in "app" folder. (_no subfolders included_)
- `AC_CACHE_INCLUDED_PATHS=app/gradle*`: All files begin with "gradle" in "app" folder. (_no subfolders included_)
- `AC_CACHE_INCLUDED_PATHS=app/*release*`: All files begin with "gradle" in "app" folder. (_no subfolders included_)

Including subfolders requires recursion. See following section for details of `**` usage.

For the examples above, if you need to exclude relevant folders and select only files, use `/\*` suffixed version of the same pattern in AC_CACHE_EXCLUDED_PATHS. It will discard all matched folders for the related include.

#### `**`

Match all folders recursively. This is used to descend into the folder tree and find all files and folders in subfolders of the current folder.

- `AC_CACHE_INCLUDED_PATHS=**/*.properties`: All files with .properties extension and folders ending with ".properties" in repository.
- `AC_CACHE_INCLUDED_PATHS=**/gradle*`: All files and folders begin with "gradle" in repository.
- `AC_CACHE_INCLUDED_PATHS=**/*release*`: All files and folders that contain "release" in repository.

We can also focus into subfolders to make recursion from there with prefixing parent folders relative to repository.

- `AC_CACHE_INCLUDED_PATHS=app/**/*.properties`: All files with .properties extension and folders ending with ".properties" in "app" folder.
- `AC_CACHE_INCLUDED_PATHS=app/**/gradle*`: All files and folders begin with "gradle" in "app" folder.
- `AC_CACHE_INCLUDED_PATHS=app/**/*release*`: All files and folders that contain "release" in "app" folder.

For all examples above, if you need to exclude relevant folders and select only files, use `/\*` suffixed version of the same pattern in AC_CACHE_EXCLUDED_PATHS. It will discard all matched folders for the related include.

#### Notice

We should be careful while using excluded paths, especially for cases that defined pattern both has match from file and folder in the same path. Let's explain the situation with an example.

Assume that we want to select all files beginning with `gradle*`.

- `AC_CACHE_INCLUDED_PATHS=**/gradle*`

With above definition we get the following files and folders:

```txt
**_gradle*.zip:
  app/gradle/
  app/gradle/b.txt
  app/gradle/c.txt
  app/gradle/a.txt
  app/gradle.x
  app/src/gradle.y
  gradle/
  gradle/wrapper/
  gradle/wrapper/gradle-wrapper.properties
  gradle/wrapper/gradle-wrapper.jar
  gradle.properties
  gradlew
  gradlew.bat
```

Since we want only files, we basically add below pattern to excludes.

- `AC_CACHE_EXCLUDED_PATHS=**/gradle*/\*`

After the modification, we get the following files:

```txt
**_gradle*.zip:
  app/gradle.x
  app/src/gradle.y
  gradle.properties
  gradlew
  gradlew.bat
```

But now we have two missing "gradle*" prefixed files under "gradle/wrapper" folder. Our folder exclude removes them from parent folder.

In order to add those missing files, we need to define an additional include pattern for "gradle" subfolder which selects "gradle*" prefixed files like before. Since we want only files, we also define an exclude pattern specific for that subfolder too.

- `AC_CACHE_INCLUDED_PATHS=**/gradle*:gradle/**/gradle*`
- `AC_CACHE_EXCLUDED_PATHS=**/gradle*/\*:gradle/**/gradle*/\*`

Now we have all "gradle*" prefixed files.

```txt
**_gradle*.zip:
  app/gradle.x
  app/src/gradle.y
  gradle.properties
  gradlew
  gradlew.bat

gradle_**_gradle*.zip:
  gradle/wrapper/gradle-wrapper.jar
  gradle/wrapper/gradle-wrapper.properties
```

As an alternative method, other "gradle*" prefixed files can be added with a specific include pattern like `**/gradle-wrapper.*` without using any extra exclude.

```txt
**_gradle-wrapper.*.zip
  gradle/wrapper/gradle-wrapper.jar
  gradle/wrapper/gradle-wrapper.properties
```
