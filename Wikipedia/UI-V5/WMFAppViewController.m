
#import "WMFAppViewController.h"
#import "Wikipedia-Swift.h"

// Frameworks
#if PIWIK_ENABLED
@import PiwikTracker;
#endif
@import Masonry;
#import <Tweaks/FBTweakInline.h>

//Utility
#import "NSDate+Utilities.h"
#import "DataHousekeeping.h"

// Networking
#import "SavedArticlesFetcher.h"
#import "SessionSingleton.h"
#import "AssetsFileFetcher.h"
#import "QueuesSingleton.h"

// Model
#import "MediaWikiKit.h"
#import "WMFSavedPagesDataSource.h"
#import "WMFRecentPagesDataSource.h"

// Views
#import "UIViewController+WMFStoryboardUtilities.h"
#import "UIStoryboard+WMFExtensions.h"
#import "UITabBarController+WMFExtensions.h"
#import "UIViewController+WMFHideKeyboard.h"
#import "UIFont+WMFStyle.h"
#import "NSString+WMFGlyphs.h"
#import "WMFStyleManager.h"

// View Controllers
#import "WMFHomeViewController.h"
#import "WMFSearchViewController.h"
#import "WMFArticleListTableViewController.h"
#import "DataMigrationProgressViewController.h"
#import "OnboardingViewController.h"
#import "WMFArticleContainerViewController.h"
#import "UIViewController+WMFArticlePresentation.h"

/**
 *  Enums for each tab in the main tab bar.
 *
 *  @warning Be sure to update `WMFAppTabCount` when these enums change, and always initialize the first enum to 0.
 *
 *  @see WMFAppTabCount
 */
typedef NS_ENUM (NSUInteger, WMFAppTabType){
    WMFAppTabTypeHome = 0,
    WMFAppTabTypeSaved,
    WMFAppTabTypeRecent
};

/**
 *  Number of tabs in the main tab bar.
 *
 *  @warning Kept as a separate constant to prevent switch statements from being considered inexhaustive. This means we
 *           need to make sure it's manually kept in sync by ensuring:
 *              - The tab enum we increment is the last one
 *              - The first tab enum is initialized to 0
 *
 *  @see WMFAppTabType
 */
static NSUInteger const WMFAppTabCount = WMFAppTabTypeRecent + 1;

static NSTimeInterval const WMFTimeBeforeRefreshingHomeScreen = 24 * 60 * 60;

static dispatch_once_t launchToken;

@interface WMFAppViewController ()<UITabBarControllerDelegate, UINavigationControllerDelegate>
@property (strong, nonatomic) IBOutlet UIView* tabControllerContainerView;

@property (nonatomic, strong) IBOutlet UIView* splashView;
@property (nonatomic, strong) UITabBarController* rootTabBarController;

@property (nonatomic, strong, readonly) WMFHomeViewController* homeViewController;
@property (nonatomic, strong, readonly) WMFArticleListTableViewController* savedArticlesViewController;
@property (nonatomic, strong, readonly) WMFArticleListTableViewController* recentArticlesViewController;

@property (nonatomic, strong) WMFLegacyImageDataMigration* imageMigration;
@property (nonatomic, strong) SavedArticlesFetcher* savedArticlesFetcher;
@property (nonatomic, strong) SessionSingleton* session;

@end

@implementation WMFAppViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)loadMainUI {
    [self configureTabController];
    [self configureHomeViewController];
    [self configureSavedViewController];
    [self configureRecentViewController];
#if PIWIK_ENABLED
    [[PiwikTracker sharedInstance] sendView:@"Home"];
#endif
}

- (void)configureTabController {
    self.rootTabBarController.delegate = self;

    for (WMFAppTabType i = 0; i < WMFAppTabCount; i++) {
        UINavigationController* navigationController = [self navigationControllerForTab:i];
        navigationController.delegate = self;
    }
}

- (void)configureHomeViewController {
    self.homeViewController.searchSite  = [self.session searchSite];
    self.homeViewController.dataStore   = self.session.dataStore;
    self.homeViewController.savedPages  = self.session.userDataStore.savedPageList;
    self.homeViewController.recentPages = self.session.userDataStore.historyList;
}

- (void)configureArticleListController:(WMFArticleListTableViewController*)controller {
    controller.dataStore = self.session.dataStore;
}

- (void)configureSavedViewController {
    [self configureArticleListController:self.savedArticlesViewController];
    if (!self.savedArticlesViewController.dataSource) {
        self.savedArticlesViewController.dataSource =
            [[WMFSavedPagesDataSource alloc] initWithSavedPagesList:[self userDataStore].savedPageList];
    }
}

- (void)configureRecentViewController {
    [self configureArticleListController:self.recentArticlesViewController];
    if (!self.recentArticlesViewController.dataSource) {
        self.recentArticlesViewController.dataSource =
            [[WMFRecentPagesDataSource alloc] initWithRecentPagesList:[self userDataStore].historyList savedPages:[self userDataStore].savedPageList];
    }
}

#pragma mark - Notifications

- (void)appDidBecomeActiveWithNotification:(NSNotification*)note {
    [self resumeApp];
}

- (void)appWillResignActiveWithNotification:(NSNotification*)note {
    [self pauseApp];
}

#pragma mark - Public

+ (WMFAppViewController*)initialAppViewControllerFromDefaultStoryBoard {
    return [[UIStoryboard wmf_appRootStoryBoard] instantiateInitialViewController];
}

- (void)launchAppInWindow:(UIWindow*)window {
    WMFStyleManager* manager = [WMFStyleManager new];
    [manager applyStyleToWindow:window];
    [WMFStyleManager setSharedStyleManager:manager];

    [window setRootViewController:self];
    [window makeKeyAndVisible];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActiveWithNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActiveWithNotification:) name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)resumeApp {
    if (![self launchCompleted]) {
        return;
    }

    if ([self shouldShowHomeScreenOnLaunch]) {
        [self.tabBarController setSelectedIndex:WMFAppTabTypeHome];
        [[self navigationControllerForTab:WMFAppTabTypeHome] popToRootViewControllerAnimated:NO];
    } else if ([self shouldShowLastReadArticleOnLaunch]) {
        MWKTitle* lastRead = [[NSUserDefaults standardUserDefaults] wmf_openArticleTitle];
        if (lastRead) {
            [[NSUserDefaults standardUserDefaults] wmf_setOpenArticleTitle:nil];
            [self.tabBarController setSelectedIndex:WMFAppTabTypeHome];
            [self.homeViewController wmf_pushArticleViewControllerWithTitle:lastRead discoveryMethod:MWKHistoryDiscoveryMethodReloadFromNetwork dataStore:self.session.dataStore];
        }
    }
}

- (void)pauseApp {
    [self downloadAssetsFilesIfNecessary];
    [self performHousekeepingIfNecessary];
}

#pragma mark - Utilities

- (BOOL)launchCompleted {
    return launchToken != 0;
}

- (BOOL)shouldShowHomeScreenOnLaunch {
    NSDate* resignActiveDate = [[NSUserDefaults standardUserDefaults] wmf_appResignActiveDate];
    if (!resignActiveDate) {
        return NO;
    }

    if (fabs([resignActiveDate timeIntervalSinceNow]) >= WMFTimeBeforeRefreshingHomeScreen) {
        return YES;
    }
    return NO;
}

- (BOOL)shouldShowLastReadArticleOnLaunch {
    NSDate* resignActiveDate = [[NSUserDefaults standardUserDefaults] wmf_appResignActiveDate];
    if (!resignActiveDate) {
        return NO;
    }

    if (fabs([resignActiveDate timeIntervalSinceNow]) <= WMFTimeBeforeRefreshingHomeScreen) {
        if (![self homeViewControllerIsDisplayingContent] && [self.tabBarController selectedIndex] == WMFAppTabTypeHome) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)homeViewControllerIsDisplayingContent {
    return [self navigationControllerForTab:WMFAppTabTypeHome].viewControllers.count > 1;
}

- (UINavigationController*)navigationControllerForTab:(WMFAppTabType)tab {
    return (UINavigationController*)[self.rootTabBarController viewControllers][tab];
}

- (UIViewController*)rootViewControllerForTab:(WMFAppTabType)tab {
    return [[[self navigationControllerForTab:tab] viewControllers] firstObject];
}

#pragma mark - Accessors

- (WMFLegacyImageDataMigration*)imageMigration {
    if (!_imageMigration) {
        _imageMigration = [[WMFLegacyImageDataMigration alloc]
                           initWithImageController:[WMFImageController sharedInstance]
                                   legacyDataStore:[MWKDataStore new]];
    }
    return _imageMigration;
}

- (SavedArticlesFetcher*)savedArticlesFetcher {
    if (!_savedArticlesFetcher) {
        _savedArticlesFetcher =
            [[SavedArticlesFetcher alloc] initWithSavedPageList:[[[SessionSingleton sharedInstance] userDataStore] savedPageList]];
    }
    return _savedArticlesFetcher;
}

- (SessionSingleton*)session {
    if (!_session) {
        _session = [SessionSingleton sharedInstance];
    }

    return _session;
}

- (MWKDataStore*)dataStore {
    return self.session.dataStore;
}

- (MWKUserDataStore*)userDataStore {
    return self.session.userDataStore;
}

- (WMFHomeViewController*)homeViewController {
    return (WMFHomeViewController*)[self rootViewControllerForTab:WMFAppTabTypeHome];
}

- (WMFArticleListTableViewController*)savedArticlesViewController {
    return (WMFArticleListTableViewController*)[self rootViewControllerForTab:WMFAppTabTypeSaved];
}

- (WMFArticleListTableViewController*)recentArticlesViewController {
    return (WMFArticleListTableViewController*)[self rootViewControllerForTab:WMFAppTabTypeRecent];
}

#pragma mark - UIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(searchLanguageDidChangeWithNotification:) name:WMFSearchLanguageDidChangeNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    dispatch_once(&launchToken, ^{
        [self showSplashView];

        [self runDataMigrationIfNeededWithCompletion:^{
            [self.imageMigration setupAndStart];
            [self.savedArticlesFetcher fetchAndObserveSavedPageList];
            [self loadMainUI];
            BOOL didShowOnboarding = [self presentOnboardingIfNeeded];
            [self hideSplashViewAnimated:!didShowOnboarding];
            [self resumeApp];
        }];
    });
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[UITabBarController class]]) {
        self.rootTabBarController = segue.destinationViewController;
        [self configureTabController];
    }
}

- (BOOL)shouldAutorotate {
    return YES;
}

#pragma mark - Onboarding

- (BOOL)shouldShowOnboarding {
    NSNumber* showOnboarding = [[NSUserDefaults standardUserDefaults] objectForKey:@"ShowOnboarding"];
    return showOnboarding.boolValue;
}

- (BOOL)presentOnboardingIfNeeded {
    if ([self shouldShowOnboarding]) {
        [self presentViewController:[OnboardingViewController wmf_initialViewControllerFromClassStoryboard]
                           animated:NO
                         completion:NULL];
        [[NSUserDefaults standardUserDefaults] setObject:@NO forKey:@"ShowOnboarding"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return YES;
    }
    return NO;
}

#pragma mark - Splash

- (void)showSplashView {
    self.splashView.hidden          = NO;
    self.splashView.layer.transform = CATransform3DIdentity;
    self.splashView.alpha           = 1.0;
}

- (void)hideSplashViewAnimated:(BOOL)animated {
    NSTimeInterval duration = animated ? 0.3 : 0.0;

    [UIView animateWithDuration:duration animations:^{
        self.splashView.layer.transform = CATransform3DMakeScale(10.0f, 10.0f, 1.0f);
        self.splashView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.splashView.hidden = YES;
        self.splashView.layer.transform = CATransform3DIdentity;
    }];
}

- (BOOL)isShowingSplashView {
    return self.splashView.hidden == NO;
}

#pragma mark - House Keeping

- (void)performHousekeepingIfNecessary {
    NSDate* lastHousekeepingDate        = [[NSUserDefaults standardUserDefaults] objectForKey:@"LastHousekeepingDate"];
    NSInteger daysSinceLastHouseKeeping = [[NSDate date] daysAfterDate:lastHousekeepingDate];
    //NSLog(@"daysSinceLastHouseKeeping = %ld", (long)daysSinceLastHouseKeeping);
    if (daysSinceLastHouseKeeping > 1) {
        //NSLog(@"Performing housekeeping...");
        DataHousekeeping* dataHouseKeeping = [[DataHousekeeping alloc] init];
        [dataHouseKeeping performHouseKeeping];
        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"LastHousekeepingDate"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

#pragma mark - Download Assets

- (void)downloadAssetsFilesIfNecessary {
    // Sync config/ios.json at most once per day.
    [[QueuesSingleton sharedInstance].assetsFetchManager.operationQueue cancelAllOperations];

    (void)[[AssetsFileFetcher alloc] initAndFetchAssetsFileOfType:WMFAssetsFileTypeConfig
                                                      withManager:[QueuesSingleton sharedInstance].assetsFetchManager
                                                           maxAge:kWMFMaxAgeDefault];
}

#pragma mark - Migration

- (void)runDataMigrationIfNeededWithCompletion:(dispatch_block_t)completion {
    DataMigrationProgressViewController* migrationVC = [[DataMigrationProgressViewController alloc] init];
    [migrationVC removeOldDataBackupIfNeeded];

    if (![migrationVC needsMigration]) {
        if (completion) {
            completion();
        }
        return;
    }

    [self presentViewController:migrationVC animated:YES completion:^{
        [migrationVC runMigrationWithCompletion:^(BOOL migrationCompleted) {
            [migrationVC dismissViewControllerAnimated:YES completion:NULL];
            if (completion) {
                completion();
            }
        }];
    }];
}

- (void)tabBarController:(UITabBarController*)tabBarController didSelectViewController:(UIViewController*)viewController {
    [self wmf_hideKeyboard];
#if PIWIK_ENABLED
    WMFAppTabType tab = [[tabBarController viewControllers] indexOfObject:viewController];
    switch (tab) {
        case WMFAppTabTypeHome: {
            [[PiwikTracker sharedInstance] sendView:@"Home"];
        }
        break;
        case WMFAppTabTypeSaved: {
            [[PiwikTracker sharedInstance] sendView:@"Saved"];
        }
        break;
        case WMFAppTabTypeRecent: {
            [[PiwikTracker sharedInstance] sendView:@"Recent"];
        }
        break;
    }
#endif
}

#pragma mark - Notifications

- (void)searchLanguageDidChangeWithNotification:(NSNotification*)note {
    [self configureHomeViewController];
}

#pragma mark - UINavigationControllerDelegate

- (void)navigationController:(UINavigationController*)navigationController
      willShowViewController:(UIViewController*)viewController
                    animated:(BOOL)animated {
    BOOL isToolbarEmpty = [viewController toolbarItems].count == 0;
    [navigationController setToolbarHidden:isToolbarEmpty];
}

@end
