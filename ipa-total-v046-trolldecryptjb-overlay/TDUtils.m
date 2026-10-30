#import "TDUtils.h"
#import "TDDumpDecrypted.h"
#import "LSApplicationProxy+AltList.h"

static NSString *getLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"lldb_output.log"];
}

// A vnode-only waiter misses the first LLDB write if the child has not yet
// created the redirected log. Poll the bounded, truncated per-launch log:
// this runs only on the background extraction queue, never on the UI thread.
static BOOL waitForContentOfFileSync(NSString *filePath, NSString *content, NSTimeInterval timeout) {
    if (filePath.length == 0 || content.length == 0 || timeout <= 0) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        NSString *output = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
        if ([output containsString:content]) return YES;
        [NSThread sleepForTimeInterval:0.15];
    } while ([deadline timeIntervalSinceNow] > 0);
    NSLog(@"[trolldecrypt-v054] timed out waiting for LLDB marker; no decryption attempted: %@", content);
    return NO;
}


static NSString *lldbQuotedProcessName(const char *executableName) {
    if (!executableName) {
        return nil;
    }
    NSString *name = [NSString stringWithUTF8String:executableName];
    if (!name) {
        return nil;
    }

    NSCharacterSet *controlSet = [NSCharacterSet controlCharacterSet];
    NSMutableString *sanitized = [NSMutableString stringWithCapacity:name.length];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ([controlSet characterIsMember:c]) {
            continue;
        }
        [sanitized appendFormat:@"%C", c];
    }

    NSString *escaped = [[sanitized stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                         stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

UIWindow *alertWindow = NULL;
UIWindow *kw = NULL;
UIViewController *root = NULL;
UIAlertController *alertController = NULL;
UIAlertController *doneController = NULL;
UIAlertController *errorController = NULL;

NSArray *appList(void) {
    NSMutableArray *apps = [NSMutableArray array];

    NSArray <LSApplicationProxy *> *installedApplications = [[LSApplicationWorkspace defaultWorkspace] atl_allInstalledApplications];
    [installedApplications enumerateObjectsUsingBlock:^(LSApplicationProxy *proxy, NSUInteger idx, BOOL *stop) {
        if (![proxy atl_isUserApplication]) return;

        NSString *bundleID = [proxy atl_bundleIdentifier];
        NSString *name = [proxy atl_nameToDisplay];
        NSString *version = [proxy atl_shortVersionString];
        NSString *executable = proxy.canonicalExecutablePath;

        if (!bundleID || !name || !version || !executable) return;

        NSDictionary *item = @{
            @"bundleID":bundleID,
            @"name":name,
            @"version":version,
            @"executable":executable
        };

        [apps addObject:item];
    }];

    NSSortDescriptor *descriptor = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
    [apps sortUsingDescriptors:@[descriptor]];

    [apps addObject:@{@"bundleID":@"", @"name":@"", @"version":@"", @"executable":@""}];

    return [apps copy];
}

NSUInteger iconFormat(void) {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 8 : 10;
}

NSArray *sysctl_ps(void) {
    NSMutableArray *array = [[NSMutableArray alloc] init];

    int numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    pid_t pids[numberOfProcesses];
    bzero(pids, sizeof(pids));
    proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    for (int i = 0; i < numberOfProcesses; ++i) {
        if (pids[i] == 0) { continue; }
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
        bzero(pathBuffer, PROC_PIDPATHINFO_MAXSIZE);
        proc_pidpath(pids[i], pathBuffer, sizeof(pathBuffer));

        if (strlen(pathBuffer) > 0) {
            NSString *processID = [[NSString alloc] initWithFormat:@"%d", pids[i]];
            NSString *processName = [[NSString stringWithUTF8String:pathBuffer] lastPathComponent];
            NSDictionary *dict = [[NSDictionary alloc] initWithObjects:[NSArray arrayWithObjects:processID, processName, nil] forKeys:[NSArray arrayWithObjects:@"pid", @"proc_name", nil]];
            
            [array addObject:dict];
        }
    }

    return [array copy];
}

void decryptApp(NSDictionary *app) {
    // Protect the already-installed 1.2024.348. It shares both executable name
    // and bundle identifier with the requested 1.2026.286. Never interpret
    // extracting the old installed app as a successful newer-app extraction.
    NSString *requestedID = app[@"bundleID"];
    NSString *requestedVersion = app[@"version"];
    if ([requestedID isEqualToString:@"com.openai.chat"] &&
        ![requestedVersion isEqualToString:@"1.2026.286"]) {
        NSLog(@"[trolldecrypt-v054] rejecting non-target installed ChatGPT version: %@", requestedVersion);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = [[UIApplication sharedApplication].delegate window].rootViewController;
            if (!presenter) return;
            UIAlertController *warning = [UIAlertController alertControllerWithTitle:@"Protected ChatGPT version"
                message:@"The installed ChatGPT is not 1.2026.286. It will not be launched, interrupted or mislabeled as a newer decrypted app."
                preferredStyle:UIAlertControllerStyleAlert];
            [warning addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [presenter presentViewController:warning animated:YES completion:nil];
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        alertWindow = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.windowLevel = UIWindowLevelAlert + 1;
        [alertWindow makeKeyAndVisible];
        
        // Show a "Decrypting!" alert on the device and block the UI
            
        kw = alertWindow;
        if([kw respondsToSelector:@selector(topmostPresentedViewController)])
            root = [kw performSelector:@selector(topmostPresentedViewController)];
        else
            root = [kw rootViewController];
        root.modalPresentationStyle = UIModalPresentationFullScreen;
    });

    NSLog(@"[trolldecrypt] decrypt...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        NSString *bundleID = app[@"bundleID"];
        NSString *name = app[@"name"];
        NSString *version = app[@"version"];
        NSString *executable = app[@"executable"];
        NSString *binaryName = [executable lastPathComponent];

        NSLog(@"[trolldecrypt] bundleID: %@", bundleID);
        NSLog(@"[trolldecrypt] name: %@", name);
        NSLog(@"[trolldecrypt] version: %@", version);
        NSLog(@"[trolldecrypt] executable: %@", executable);
        NSLog(@"[trolldecrypt] binaryName: %@", binaryName);

        // V045: Fail closed before LLDB --waitfor. Never attach to or kill an
        // already-running binary with the same basename as the target.
        NSArray *processes = sysctl_ps();
        for (NSDictionary *process in processes) {
            if ([process[@"proc_name"] isEqualToString:binaryName]) {
                NSLog(@"[trolldecrypt-v045] conflicting active executable; refusing: %@", binaryName);
                dispatch_async(dispatch_get_main_queue(), ^{
                    errorController = [UIAlertController alertControllerWithTitle:@"Existing app running"
                        message:@"A process with this executable name is already running. Refusing to attach or stop it."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                        [kw removeFromSuperview];
                        kw.hidden = YES;
                    }]];
                    [root presentViewController:errorController animated:YES completion:nil];
                });
                return;
            }
        }

        NSLog(@"[trolldecrypt] lldb --waitfor for '%@'...", binaryName);
        pid_t lldb_pid = attachLLDBToProcessByName([binaryName UTF8String], -1);//-1 for unknown
        
        if (lldb_pid <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                errorController = [UIAlertController alertControllerWithTitle:@"Error: lldb" message:@"Failed to start lldb. Make sure lldb is installed." preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [errorController dismissViewControllerAnimated:NO completion:nil];
                    [kw removeFromSuperview];
                    kw.hidden = YES;
                }];
                [errorController addAction:okAction];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }
        
        // V045: Do not kill any pre-existing process. The pre-attach guard
        // above rejects a conflicting name rather than interrupting the user.
        
        NSLog(@"[trolldecrypt] launch app and lldb force pause...");
        [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleID suspended:YES]; // Launch app in suspended state
        // Merely logging "Architecture set to" does NOT prove LLDB caught
        // the target; require a real stopped-process message before reading it.
        BOOL stopped = waitForContentOfFileSync(getLogPath(), @"Process ", 30.0) &&
                       waitForContentOfFileSync(getLogPath(), @"stopped", 2.0);
        if (!stopped) {
            detachLLDB(lldb_pid);
            dispatch_async(dispatch_get_main_queue(), ^{
                errorController = [UIAlertController alertControllerWithTitle:@"LLDB did not stop target"
                    message:@"No verified stopped-process marker. No memory extraction was attempted."
                    preferredStyle:UIAlertControllerStyleAlert];
                [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                    [kw removeFromSuperview];
                    kw.hidden = YES;
                }]];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }

        // Get PID after lldb caught it
        pid_t pid = -1;
        processes = sysctl_ps();
        for (NSDictionary *process in processes) {
            NSString *proc_name = process[@"proc_name"];
            if ([proc_name isEqualToString:binaryName]) {
                pid_t candidatePID = [process[@"pid"] intValue];
                char resolvedPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
                int pathLength = proc_pidpath(candidatePID, resolvedPath, sizeof(resolvedPath));
                NSString *candidatePath = pathLength > 0 ? [NSString stringWithUTF8String:resolvedPath] : nil;
                NSString *expectedCanonical = [executable stringByResolvingSymlinksInPath];
                NSString *actualCanonical = [candidatePath stringByResolvingSymlinksInPath];
                if (candidatePath && [expectedCanonical isEqualToString:actualCanonical]) {
                    pid = candidatePID;
                    NSLog(@"[trolldecrypt-v045] Verified target PID %d by full executable path", pid);
                    break;
                }
                NSLog(@"[trolldecrypt-v045] same process name but different executable path; refusing");
            }
        }

        if (pid == -1) {
            detachLLDB(lldb_pid);
            dispatch_async(dispatch_get_main_queue(), ^{
                [alertController dismissViewControllerAnimated:NO completion:nil];
                NSLog(@"[trolldecrypt] failed to get pid for binary name: %@", binaryName);

                errorController = [UIAlertController alertControllerWithTitle:@"Error: -1" message:[NSString stringWithFormat:@"Failed to get PID for binary name: %@", binaryName] preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Ok", @"Ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    NSLog(@"[trolldecrypt] Ok action");
                    [errorController dismissViewControllerAnimated:NO completion:nil];
                    [kw removeFromSuperview];
                    kw.hidden = YES;
                }];

                [errorController addAction:okAction];
                [root presentViewController:errorController animated:YES completion:nil];
            });

            return;
        }

        NSLog(@"[trolldecrypt] pid: %d", pid);

        bfinject_rocknroll(pid, name, version, lldb_pid);
    });
}

pid_t attachLLDBToProcessByName(const char *executableName, pid_t target_pid) {
    NSLog(@"[trolldecrypt] Attaching lldb to executable: %s (PID: %d)", executableName, target_pid);
    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lldb_attach.txt"];
    NSString *quotedName = lldbQuotedProcessName(executableName);
    if (!quotedName) {
        NSLog(@"[trolldecrypt] Invalid executable name for lldb attach");
        return 0;
    }
    NSString *scriptContent = [NSString stringWithFormat:
        @"process attach --name %@ --waitfor\n", quotedName];
    [scriptContent writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *logPath = getLogPath();

    pid_t lldb_pid = 0;
    const char *lldb_path = "/var/jb/usr/bin/lldb"; // TODO: please edit to use auto scheme for rootful/roothide, i'm lazy and forgot to do it
    const char *args[] = {
        "lldb",
        "-s", [scriptPath UTF8String],  // Source script file
        NULL
    };
    
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, [logPath UTF8String], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, [logPath UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);
    
    int status = posix_spawn(&lldb_pid, lldb_path, &actions, NULL, (char *const *)args, NULL);
    posix_spawn_file_actions_destroy(&actions);
    
    if (status == 0) {
        NSLog(@"[trolldecrypt] lldb spawned done, lldb PID: %d", lldb_pid);
        NSLog(@"[trolldecrypt] lldb output: %@", logPath);
        
        BOOL commandObserved = waitForContentOfFileSync(logPath, @"process attach --name", 5.0);
        // The command echo is NOT evidence of a successful target attach.
        // The actual stopped-process evidence is checked after launch.
        if (!commandObserved || kill(lldb_pid, 0) != 0) {
            NSLog(@"[trolldecrypt-v054] lldb startup or command-echo failed");
            detachLLDB(lldb_pid);
            lldb_pid = 0;
        } else {
            NSLog(@"[trolldecrypt-v054] lldb waiting for target; not yet attached");
        }
    } else {
        NSLog(@"[trolldecrypt] fail to spawn lldb: %d", status);
        lldb_pid = 0;
    }
    
    return lldb_pid;
}

// Detach lldb from process
void detachLLDB(pid_t lldb_pid) {
    if (lldb_pid > 0) {
        NSLog(@"[trolldecrypt] Detaching lldb (PID: %d)", lldb_pid);

        kill(lldb_pid, SIGTERM);
        
        sleep(1);
      
        if (kill(lldb_pid, 0) == 0) {
            NSLog(@"[trolldecrypt] lldb still running, sending SIGKILL");
            kill(lldb_pid, SIGKILL);
        }
        
        NSLog(@"[trolldecrypt] lldb detached successfully");

        // Reap the lldb process
        int unused;
        waitpid(lldb_pid, &unused, WNOHANG);
    }
}

void bfinject_rocknroll(pid_t pid, NSString *appName, NSString *version, pid_t lldb_pid) {
    NSLog(@"[trolldecrypt] decrypt...");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{;
        NSLog(@"[trolldecrypt] Process PID: %d, lldb PID: %d", pid, lldb_pid);

		// Get full path
		char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        proc_pidpath(pid, pathbuf, sizeof(pathbuf));
		const char *fullPathStr = pathbuf;

        NSLog(@"[trolldecrypt] fullPathStr: %s", fullPathStr);
        NSLog(@"[trolldecrypt] Process is already PAUSED by lldb");
        
        DumpDecrypted *dd = [[DumpDecrypted alloc] initWithPathToBinary:[NSString stringWithUTF8String:fullPathStr] appName:appName appVersion:version];
        if(!dd) {
            NSLog(@"[trolldecrypt] ERROR: failed to get DumpDecrypted instance");
            return;
        }

        NSLog(@"[trolldecrypt] Full path to app: %s   ///   IPA File: %@", fullPathStr, [dd IPAPath]);

        dispatch_async(dispatch_get_main_queue(), ^{
            alertWindow = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
            alertWindow.rootViewController = [UIViewController new];
            alertWindow.windowLevel = UIWindowLevelAlert + 1;
            [alertWindow makeKeyAndVisible];
            
            // Show a "Decrypting!" alert on the device and block the UI
            alertController = [UIAlertController
                alertControllerWithTitle:@"Decrypting"
                message:@"Please wait, this will take a few seconds..."
                preferredStyle:UIAlertControllerStyleAlert];
                
            kw = alertWindow;
            if([kw respondsToSelector:@selector(topmostPresentedViewController)])
                root = [kw performSelector:@selector(topmostPresentedViewController)];
            else
                root = [kw rootViewController];
            root.modalPresentationStyle = UIModalPresentationFullScreen;
            [root presentViewController:alertController animated:YES completion:nil];
        });
        
        NSLog(@"[trolldecrypt] Starting decryption while process is paused...");
        BOOL fullyDumped = [dd createIPAFile:pid];
        NSLog(@"[trolldecrypt] Detaching lldb...");
        detachLLDB(lldb_pid);
        if (!fullyDumped) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [alertController dismissViewControllerAnimated:NO completion:nil];
                errorController = [UIAlertController alertControllerWithTitle:@"Incomplete dump"
                    message:@"Required encrypted startup images were not all recovered. No valid IPA was produced."
                    preferredStyle:UIAlertControllerStyleAlert];
                [errorController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [kw removeFromSuperview];
                    kw.hidden = YES;
                }]];
                [root presentViewController:errorController animated:YES completion:nil];
            });
            return;
        }
        NSLog(@"[trolldecrypt-v045] all six required startup images produced; offline V023 check required");

        // Dismiss the alert box
        dispatch_async(dispatch_get_main_queue(), ^{
            [alertController dismissViewControllerAnimated:NO completion:nil];

            doneController = [UIAlertController alertControllerWithTitle:@"Decryption Complete!" message:[NSString stringWithFormat:@"IPA file saved to:\n%@\n\nThanks to lldb so we can archive this!", [dd IPAPath]] preferredStyle:UIAlertControllerStyleAlert];

            UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Ok", @"Ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [kw removeFromSuperview];
                kw.hidden = YES;
            }];
            [doneController addAction:okAction];

            if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]) {
                UIAlertAction *openAction = [UIAlertAction actionWithTitle:@"Show in Filza" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [kw removeFromSuperview];
                    kw.hidden = YES;

                    NSString *urlString = [NSString stringWithFormat:@"filza://view%@", [dd IPAPath]];
                    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlString] options:@{} completionHandler:nil];
                }];
                [doneController addAction:openAction];
            }

            [root presentViewController:doneController animated:YES completion:nil];
        }); // dispatch on main
                    
        NSLog(@"[trolldecrypt] Over and out.");
    }); // dispatch in background
    
    NSLog(@"[trolldecrypt] All done.");
}

NSArray *decryptedFileList(void) {
    NSMutableArray *files = [NSMutableArray array];
    NSMutableArray *fileNames = [NSMutableArray array];

    // iterate through all files in the Documents directory
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *directoryEnumerator = [fileManager enumeratorAtPath:docPath()];

    NSString *file;
    while (file = [directoryEnumerator nextObject]) {
        if ([[file pathExtension] isEqualToString:@"ipa"]) {
            NSString *filePath = [[docPath() stringByAppendingPathComponent:file] stringByStandardizingPath];

            NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:filePath error:nil];
            NSDate *modificationDate = fileAttributes[NSFileModificationDate];

            NSDictionary *fileInfo = @{@"fileName": file, @"modificationDate": modificationDate};
            [files addObject:fileInfo];
        }
    }

    // Sort the array based on modification date
    NSArray *sortedFiles = [files sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSDate *date1 = [obj1 objectForKey:@"modificationDate"];
        NSDate *date2 = [obj2 objectForKey:@"modificationDate"];
        return [date2 compare:date1];
    }];

    // Get the file names from the sorted array
    for (NSDictionary *fileInfo in sortedFiles) {
        [fileNames addObject:[fileInfo objectForKey:@"fileName"]];
    }

    return [fileNames copy];
}

NSString *docPath(void) {
    NSError * error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/TrollDecrypt/decrypted" withIntermediateDirectories:YES attributes:nil error:&error];
    if (error != nil) {
        NSLog(@"[trolldecrypt] error creating directory: %@", error);
    }

    return @"/var/mobile/Documents/TrollDecrypt/decrypted";
}

void decryptAppWithPID(pid_t pid) {
    // generate App NSDictionary object to pass into decryptApp()
    // proc_pidpath(self.pid, buffer, sizeof(buffer));
    NSString *message = nil;
    NSString *error = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        alertWindow = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.windowLevel = UIWindowLevelAlert + 1;
        [alertWindow makeKeyAndVisible];
        
        // Show a "Decrypting!" alert on the device and block the UI
            
        kw = alertWindow;
        if([kw respondsToSelector:@selector(topmostPresentedViewController)])
            root = [kw performSelector:@selector(topmostPresentedViewController)];
        else
            root = [kw rootViewController];
        root.modalPresentationStyle = UIModalPresentationFullScreen;
    });

    NSLog(@"[trolldecrypt] pid: %d", pid);

    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    proc_pidpath(pid, pathbuf, sizeof(pathbuf));

    NSString *executable = [NSString stringWithUTF8String:pathbuf];
    NSString *path = [executable stringByDeletingLastPathComponent];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = infoPlist[@"CFBundleIdentifier"];

    if (!bundleID) {
        error = @"Error: -2";
        message = [NSString stringWithFormat:@"Failed to get bundle id for pid: %d", pid];
    }

    LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!app) {
        error = @"Error: -3";
        message = [NSString stringWithFormat:@"Failed to get LSApplicationProxy for bundle id: %@", bundleID];
    }

    if (message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [alertController dismissViewControllerAnimated:NO completion:nil];
            NSLog(@"[trolldecrypt] failed to get bundleid for pid: %d", pid);

            errorController = [UIAlertController alertControllerWithTitle:error message:message preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Ok", @"Ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSLog(@"[trolldecrypt] Ok action");
                [errorController dismissViewControllerAnimated:NO completion:nil];
                [kw removeFromSuperview];
                kw.hidden = YES;
            }];

            [errorController addAction:okAction];
            [root presentViewController:errorController animated:YES completion:nil];
        });
    }

    NSLog(@"[trolldecrypt] app: %@", app);

    NSDictionary *appInfo = @{
        @"bundleID":bundleID,
        @"name":[app atl_nameToDisplay],
        @"version":[app atl_shortVersionString],
        @"executable":executable
    };

    NSLog(@"[trolldecrypt] appInfo: %@", appInfo);

    dispatch_async(dispatch_get_main_queue(), ^{
        [alertController dismissViewControllerAnimated:NO completion:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Decrypt" message:[NSString stringWithFormat:@"Decrypt %@?", appInfo[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        UIAlertAction *decrypt = [UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            decryptApp(appInfo);
        }];

        [alert addAction:decrypt];
        [alert addAction:cancel];
        
        [root presentViewController:alert animated:YES completion:nil];
    });
}

// void github_fetchLatedVersion(NSString *repo, void (^completionHandler)(NSString *latestVersion)) {
//     NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repo];
//     NSURL *url = [NSURL URLWithString:urlString];

//     NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
//         if (!error) {
//             if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
//                 NSError *jsonError;
//                 NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

//                 if (!jsonError) {
//                     NSString *version = [json[@"tag_name"] stringByReplacingOccurrencesOfString:@"v" withString:@""];
//                     completionHandler(version);
//                 }
//             }
//         }
//     }];

//     [task resume];
// }

void fetchLatestTrollDecryptVersion(void (^completionHandler)(NSString *version)) {
    //github_fetchLatedVersion(@"donato-fiore/TrollDecrypt", completionHandler);
}

NSString *trollDecryptVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
}