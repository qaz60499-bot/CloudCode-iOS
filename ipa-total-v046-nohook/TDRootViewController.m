#import "TDRootViewController.h"
#import "TDFileManagerViewController.h"
#import "TDUtils.h"
#import <spawn.h>
#import <rootless.h>
#import "appstoretrollerKiller/TSUtil.h"

@implementation TDRootViewController

- (void)loadView {
    [super loadView];

    self.apps = appList();
    self.title = @"TrollDecrypt";
	self.navigationController.navigationBar.prefersLargeTitles = YES;
    
    // Initialize hook preferences
    self.hookPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.trolldecrypt.hook"];
    
    // Right button - info
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(about:)];
    
    // Left button - folder
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"folder"] style:UIBarButtonItemStylePlain target:self action:@selector(openDocs:)];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshApps:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;
}

- (void)viewDidAppear:(bool)animated {
    [super viewDidAppear:animated];

    fetchLatestTrollDecryptVersion(^(NSString *latestVersion) {
        NSString *currentVersion = trollDecryptVersion();
        NSComparisonResult result = [currentVersion compare:latestVersion options:NSNumericSearch];
        NSLog(@"[trolldecrypt] Current version: %@, Latest version: %@", currentVersion, latestVersion);
        if (result == NSOrderedAscending) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Update Available" message:@"An update for TrollDecrypt is available." preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
                UIAlertAction *update = [UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/donato-fiore/TrollDecrypt/releases/latest"]] options:@{} completionHandler:nil];
                }];

                [alert addAction:update];
                [alert addAction:cancel];
                [self presentViewController:alert animated:YES completion:nil];
            });
        }
    });
}

- (void)openDocs:(id)sender {
    TDFileManagerViewController *fmVC = [[TDFileManagerViewController alloc] init];
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:fmVC];
    [self presentViewController:navController animated:YES completion:nil];
}

- (void)about:(id)sender {
    // V046 research-only application: no App Store version spoofing and no
    // system-wide appstored/installd tweak or daemon restart controls.
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"IPA Total Isolated Research"
        message:@"No App Store hooks, system daemon modifications, or background services are installed. Decryption is permitted only for an installed and authorized executable that can be safely mapped."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshApps:(UIRefreshControl *)refreshControl {
    self.apps = appList();
    [self.tableView reloadData];
    [refreshControl endRefreshing];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // Section 0: Apps, Section 1: Advanced
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { 
    if (section == 0) {
        return self.apps.count - 1; // Exclude the placeholder
    } else {
        return 1; // Advanced option
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return @"Installed Apps";
    } else {
        return @"Advanced";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"AppCell";
    UITableViewCell *cell;
    
    if (indexPath.section == 0) {
        cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
        if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
    
        NSDictionary *app = self.apps[indexPath.row];

        cell.textLabel.text = app[@"name"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", app[@"version"], app[@"bundleID"]];
        cell.imageView.image = [UIImage _applicationIconImageForBundleIdentifier:app[@"bundleID"] format:iconFormat() scale:[UIScreen mainScreen].scale];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        
        cell.textLabel.text = @"Advanced";
        cell.detailTextLabel.text = @"Decrypt app from a specified PID";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 80.0f;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *alert;
    
    if (indexPath.section == 0) {
        NSDictionary *app = self.apps[indexPath.row];

        alert = [UIAlertController alertControllerWithTitle:@"Decrypt" message:[NSString stringWithFormat:@"Decrypt %@?", app[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        UIAlertAction *decrypt = [UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            decryptApp(app);
        }];

        [alert addAction:decrypt];
        [alert addAction:cancel];
    } else {
        alert = [UIAlertController alertControllerWithTitle:@"Decrypt" message:@"Enter PID to decrypt" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"PID";
            textField.keyboardType = UIKeyboardTypeNumberPad;
        }];

        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        UIAlertAction *decrypt = [UIAlertAction actionWithTitle:@"Decrypt" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *pid = alert.textFields.firstObject.text;
            decryptAppWithPID([pid intValue]);
        }];

        [alert addAction:decrypt];
        [alert addAction:cancel];
    }

    [self presentViewController:alert animated:YES completion:nil];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end

