/*
 * Copyright 2012, Oracle and/or its affiliates. All rights reserved.
 *
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <jni.h>
#include <pwd.h>
#include <sys/types.h>
#include <sys/sysctl.h>

#define JAVA_LAUNCH_ERROR "JavaLaunchError"

#define JVM_RUNTIME_KEY "JVMRuntime"
#define WORKING_DIR "WorkingDirectory"
#define JVM_MAIN_CLASS_NAME_KEY "JVMMainClassName"
#define JVM_OPTIONS_KEY "JVMOptions"
#define JVM_DEFAULT_OPTIONS_KEY "JVMDefaultOptions"
#define JVM_ARGUMENTS_KEY "JVMArguments"
#define JVM_CLASSPATH_KEY "JVMClassPath"
#define JVM_DEBUG_KEY "JVMDebug"

#define JVM_RUN_JAR "JVMJARLauncher"


#define UNSPECIFIED_ERROR "An unknown error occurred."

#define APP_ROOT_PREFIX "$APP_ROOT"
#define JVM_RUNTIME "$JVM_RUNTIME"

#define LIBJLI_DY_LIB "libjli.dylib"


typedef int (JNICALL *JLI_Launch_t)(int argc, char ** argv,
                                    int jargc, const char** jargv,
                                    int appclassc, const char** appclassv,
                                    const char* fullversion,
                                    const char* dotversion,
                                    const char* pname,
                                    const char* lname,
                                    jboolean javaargs,
                                    jboolean cpwildcard,
                                    jboolean javaw,
                                    jint ergo);


static char** progargv = NULL;
static int progargc = 0;
static int launchCount = 0;

int launch(char *, int, char **);

NSString * convertRelativeFilePath(NSString *);
NSString * addDirectoryToSystemArguments(NSUInteger, NSSearchPathDomainMask, NSString *, NSMutableArray *);


int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int result;
    @try {
        if ((argc > 1) && (launchCount == 0)) {
            progargc = argc - 1;
            progargv = &argv[1];
        }

        launch(argv[0], progargc, progargv);
        result = 0;
    } @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setAlertStyle:NSAlertStyleCritical];
        [alert setMessageText:[exception reason]];
        [alert runModal];

        result = 1;
    }

    [pool drain];

    return result;
}



int launch(char *commandName, int progargc, char *progargv[]) {
    // Preparation for jnlp launcher arguments
    const char *const_jargs = NULL;
    const char *const_appclasspath = NULL;

    // Get the main bundle
    NSBundle *mainBundle = [NSBundle mainBundle];

    // Get the main bundle's info dictionary
    NSDictionary *infoDictionary = [mainBundle infoDictionary];

    // Set the working directory based on config, defaulting to the user's home directory
    NSString *workingDir = [infoDictionary objectForKey:@WORKING_DIR];
    if (workingDir != nil) {
        workingDir = [workingDir stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        chdir([workingDir UTF8String]);
    }

    // Locate the JLI_Launch() function
    NSString *runtime = [infoDictionary objectForKey:@JVM_RUNTIME_KEY];
    NSString *runtimePath = [[mainBundle builtInPlugInsPath] stringByAppendingPathComponent:runtime];

    NSString *javaDylib = NULL;

    // If a runtime is set, we really want it. If it is not there, we will fail later on.
    NSFileManager *fm = [[NSFileManager alloc] init];
    for (id dylibRelPath in @[@"Contents/Home/lib"]) {
        NSString *candidate = [[runtimePath stringByAppendingPathComponent:dylibRelPath] stringByAppendingPathComponent:@LIBJLI_DY_LIB];
        BOOL isDir;
        BOOL javaDylibFileExists = [fm fileExistsAtPath:candidate isDirectory:&isDir];
        if (javaDylibFileExists && !isDir) {
            javaDylib = candidate;
            break;
        }
    }

    const char *libjliPath = NULL;
    if (javaDylib != nil)
    {
        libjliPath = [javaDylib fileSystemRepresentation];
    }


    void *libJLI = dlopen(libjliPath, RTLD_LAZY);

    JLI_Launch_t jli_LaunchFxnPtr = NULL;
    if (libJLI != NULL) {
        jli_LaunchFxnPtr = dlsym(libJLI, "JLI_Launch");
    }

    // Set the class path
    NSFileManager *defaultFileManager = [NSFileManager defaultManager];
    NSString *mainBundlePath = [mainBundle bundlePath];

    // make sure the bundle path does not contain a colon, as that messes up the java.class.path,
    // because colons are used a path separators and cannot be escaped.

    // funny enough, Finder does not let you create folder with colons in their names,
    // but when you create a folder with a slash, e.g. "audio/video", it is accepted
    // and turned into... you guessed it, a colon:
    // "audio:video"
    if ([mainBundlePath rangeOfString:@":"].location != NSNotFound) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
                                 reason:NSLocalizedString(@"BundlePathContainsColon", @UNSPECIFIED_ERROR)
                               userInfo:nil] raise];
    }


    // Set the class path
    NSString *javaPath = [mainBundlePath stringByAppendingString:@"/Contents/Java"];
    NSMutableArray *systemArguments = [[NSMutableArray alloc] init];
    NSMutableString *classPath = [NSMutableString stringWithString:@"-Djava.class.path="];

    // Set the library path
    NSString *libraryPath = [NSString stringWithFormat:@"-Djava.library.path=%@/Contents/MacOS", mainBundlePath];
    [systemArguments addObject:libraryPath];

    // Get the VM options
    NSMutableArray *options = [[infoDictionary objectForKey:@JVM_OPTIONS_KEY] mutableCopy];
    if (options == nil) {
        options = [NSMutableArray array];
    }

    // Get the VM default options
    NSArray *defaultOptions = [NSArray array];
    NSDictionary *defaultOptionsDict = [infoDictionary objectForKey:@JVM_DEFAULT_OPTIONS_KEY];
    if (defaultOptionsDict != nil) {
        NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithDictionary: defaultOptionsDict];
        // Replace default options with user specific options, if available
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        // Create special key that should be used by Java's java.util.Preferences impl
        // Requires us to use "/" + bundleIdentifier.replace('.', '/') + "/JVMOptions/" as node on the Java side
        // Beware: bundleIdentifiers shorter than 3 segments are placed in a different file!
        // See java/util/prefs/MacOSXPreferences.java of OpenJDK for details
        NSString *bundleDictionaryKey = [mainBundle bundleIdentifier];
        bundleDictionaryKey = [bundleDictionaryKey stringByReplacingOccurrencesOfString:@"." withString:@"/"];
        bundleDictionaryKey = [NSString stringWithFormat: @"/%@/", bundleDictionaryKey];

        NSDictionary *bundleDictionary = [userDefaults dictionaryForKey: bundleDictionaryKey];
        if (bundleDictionary != nil) {
            NSDictionary *jvmOptionsDictionary = [bundleDictionary objectForKey: @"JVMOptions/"];
            for (NSString *key in jvmOptionsDictionary) {
                NSString *value = [jvmOptionsDictionary objectForKey:key];
                [defaults setObject: value forKey: key];
            }
        }
        defaultOptions = [defaults allValues];
    }
    
    // Set the AppleWindowTabbingMode to not squash all new JFrames into tabs within
    // a single window when the user has set SystemPrefs:General:PreferTabs:always-when-opening-documents
    // which is unfortunately the default in macOS 11
    [[NSUserDefaults standardUserDefaults] setValue:@"manual" forKey:@"AppleWindowTabbingMode"];

    // Get the application arguments
    NSMutableArray *arguments = [[infoDictionary objectForKey:@JVM_ARGUMENTS_KEY] mutableCopy];
    if (arguments == nil) {
        arguments = [NSMutableArray array];
    }

    // Check for a defined JAR File below the Contents/Java folder
    // If set, use this instead of a classpath setting
    NSString *jarlauncher = [infoDictionary objectForKey:@JVM_RUN_JAR];

    // Get the main class name
    NSString *mainClassName = [infoDictionary objectForKey:@JVM_MAIN_CLASS_NAME_KEY];

    bool runningModule = [mainClassName rangeOfString:@"/"].location != NSNotFound;
    
    // It is impossible to combine modules and jar launcher
    if ( runningModule && jarlauncher != nil ) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:@"Modules cannot be used in conjuction with jar launcher"
            userInfo:nil] raise];
    }

    // Either mainClassName or jarLauncher has to be set since this is not a jnlpLauncher
    if ( mainClassName == nil && jarlauncher == nil ) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:NSLocalizedString(@"MainClassNameRequired", @UNSPECIFIED_ERROR)
            userInfo:nil] raise];
    }
    
    // If a jar file is defined as launcher, disacard the javaPath
    if ( jarlauncher != nil ) {
        [classPath appendFormat:@":%@/%@", javaPath, jarlauncher];
    } else if ( !runningModule ) {
        NSArray *cp = [infoDictionary objectForKey:@JVM_CLASSPATH_KEY];
        if (cp == nil) {
            // Implicit classpath, so use the contents of the "Java" folder to build an explicit classpath
            [classPath appendFormat:@"%@/Classes", javaPath];
            NSFileManager *defaultFileManager = [NSFileManager defaultManager];
            NSArray *javaDirectoryContents = [defaultFileManager contentsOfDirectoryAtPath:javaPath error:nil];
            if (javaDirectoryContents == nil) {
                [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
                                         reason:NSLocalizedString(@"JavaDirectoryNotFound", @UNSPECIFIED_ERROR)
                                       userInfo:nil] raise];
            }
            for (NSString *file in javaDirectoryContents) {
                if ([file hasSuffix:@".jar"]) {
                    [classPath appendFormat:@":%@/%@", javaPath, file];
                }
            }
        } else {
            // Explicit ClassPath
            int k = 0;
            for (NSString *file in cp) {
                if (k++ > 0) [classPath appendString:@":"]; // add separator if needed
                file = [file stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
                [classPath appendString:file];
            }
        }
    }

    if ( classPath != nil && !runningModule ) {
        [systemArguments addObject:classPath];
    }

    // get the user's home directory, independent of the sandbox container
    int bufsize;
    if ((bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)) != -1) {
        char buffer[bufsize];
        struct passwd pwd, *result = NULL;
        if (getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0 && result) {
            [systemArguments addObject:[NSString stringWithFormat:@"-DUserHome=%s", pwd.pw_dir]];
        }
    }


    // Mojave Dark Mode enabled?
    NSString *osxMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    BOOL isDarkMode = (osxMode != nil && [osxMode isEqualToString:@"Dark"]);

    NSString *darkModeEnabledVar = [NSString stringWithFormat:@"-DDarkMode=%s",
                                    (isDarkMode ? "true" : "false")];
    [systemArguments addObject:darkModeEnabledVar];


    // Remove -psn argument
    int newProgargc = progargc;
    char *newProgargv[newProgargc];
    for (int i = 0; i < progargc; i++) {
        newProgargv[i] = progargv[i];
    }

    // replace $APP_ROOT in environment variables
    NSDictionary* environment = [[NSProcessInfo processInfo] environment];
    for (NSString* key in environment) {
        NSString* value = [environment objectForKey:key];
        NSString* newValue = [value stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        if (![newValue isEqualToString:value]) {
            setenv([key UTF8String], [newValue UTF8String], 1);
        }
    }

    // Initialize the arguments to JLI_Launch()
    // +5 due to the special directories and the sandbox enabled property
    int argc = 1 + [systemArguments count] + [options count] + [defaultOptions count] + 1 + [arguments count] + newProgargc;
    if (runningModule)
        argc++;

    char *argv[argc + 1];
    argv[argc] = NULL; /* Launch_JLI can crash if the argv array is not null-terminated: 9074879 */

    int i = 0;
    argv[i++] = commandName;
    for (NSString *systemArgument in systemArguments) {
        argv[i++] = strdup([systemArgument UTF8String]);
    }

    for (NSString *option in options) {
        option = [option stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        option = [option stringByReplacingOccurrencesOfString:@JVM_RUNTIME withString:runtimePath];
        argv[i++] = strdup([option UTF8String]);
    }

    for (NSString *defaultOption in defaultOptions) {
        defaultOption = [defaultOption stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([defaultOption UTF8String]);
    }

    if (runningModule) {
        argv[i++] = "-m";
        argv[i++] = strdup([mainClassName UTF8String]);
    } else {
        argv[i++] = strdup([mainClassName UTF8String]);
    }

    for (NSString *argument in arguments) {
        argument = [argument stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([argument UTF8String]);
    }

    int ctr = 0;
    for (ctr = 0; ctr < newProgargc; ctr++) {
        argv[i++] = newProgargv[ctr];
    }

    launchCount++;

    // Invoke JLI_Launch()
    return jli_LaunchFxnPtr(argc, argv,
                            sizeof(&const_jargs) / sizeof(char *), &const_jargs,
                            sizeof(&const_appclasspath) / sizeof(char *), &const_appclasspath,
                            "",
                            "",
                            "java",
                            "java",
                            (const_jargs != NULL) ? JNI_TRUE : JNI_FALSE,
                            FALSE,
                            FALSE,
                            0);
}


NSString * convertRelativeFilePath(NSString * path) {
    return [path stringByStandardizingPath];
}


NSString * addDirectoryToSystemArguments(NSUInteger searchPath, NSSearchPathDomainMask domainMask,
                                         NSString *systemProperty, NSMutableArray *systemArguments) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(searchPath,domainMask, YES);
    if ([paths count] > 0) {
        NSString *basePath = [paths objectAtIndex:0];
        NSString *directory = [NSString stringWithFormat:@"-D%@=%@", systemProperty, basePath];
        [systemArguments addObject:directory];
        return basePath;
    }
    return nil;
}
