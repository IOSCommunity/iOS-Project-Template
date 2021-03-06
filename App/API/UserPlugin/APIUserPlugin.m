
#import "APIUserPlugin.h"
#import "API.h"
#import "debug.h"

extern NSString *const APIURLLogin;
extern NSString *const APIURLForgetPassword;
extern NSString *const APIURLUserInfo;

NSString *const UDkLastUserAccount = @"Last User Account";
NSString *const UDkUserPass = @"User Password";
NSString *const UDkUserRemeberPass = @"Should Remember User Password";
NSString *const UDkUserAutoLogin = @"Should Auto Login Into User Profile";

@interface APIUserPlugin ()
@property (weak, nonatomic) API *master;
@property (strong, nonatomic) NSUserDefaults *userDefaults; // Not used

@property (readwrite, nonatomic) BOOL isLoggedIn;
@property (readwrite, nonatomic) BOOL isLogining;
@property (readwrite, nonatomic) BOOL isFetchingUserInformation;

@end

@implementation APIUserPlugin

- (instancetype)init {
    RFAssert(false, @"You should call initWithMaster: instead.");
    return nil;
}

- (void)onInit {
    [super onInit];
    
    self.token = @"";
    [self loadProfileConfig];
}

- (void)afterInit {
    [super afterInit];
    
    if (DebugAPISkipLogin) {
        self.isLoggedIn = YES;
    }
    
    if (self.shouldAutoLogin) {
        [self loginWithCallback:^(BOOL success, NSError *error) {
            if (!success) {
                [self.master alertError:error title:nil];
            }
        }];
    }
}

#pragma mark - 登入

- (void)loginWithCallback:(void (^)(BOOL success, NSError *error))callback {
    NSParameterAssert(callback);
    if (self.isLoggedIn || self.isLogining) return;
    
    if (!self.userAccount.length || !self.userPassword.length) {
        if (callback) {
            callback(NO, [NSError errorWithDomain:[NSBundle mainBundle].bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: @"User Name or Password is nil"}]);
        }
        return;
    }
    
    self.isLogining = YES;

    [self.master send:APIURLLogin parameters:@{
        @"username" : self.userAccount,
        @"password" : self.userPassword
    } success:^(id JSONObject) {
        BOOL isSuccess = NO;
        NSError __autoreleasing *e;

        if ([JSONObject isKindOfClass:[NSDictionary class]]) {
            self.userID = [JSONObject[@"uid"] intValue];
            self.token = JSONObject[@"token"];

            if (self.userID) {
                [self saveProfileConfig];
                isSuccess = YES;
                self.isLoggedIn = YES;
            }
            else {
                e = [NSError errorWithDomain:[NSBundle mainBundle].bundleIdentifier code:0 userInfo:@{ NSLocalizedDescriptionKey: JSONObject[@"result"] }];
            }
        }

        if (callback) {
            callback(isSuccess, e);
        }

        if (self.shouldAutoFetchOtherUserInformationAfterLogin) {
            [self fetchUserInformationCompletion:nil];
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (callback) {
            callback(NO, error);
        }
    } completion:^(AFHTTPRequestOperation *operation) {
        self.isLogining = NO;
    }];
}

- (void)logout {
    self.isLoggedIn = NO;
    self.userID = 0;
    [self resetProfileConfig];
}

#pragma mark -
- (void)resetPasswordWithInfo:(NSDictionary *)recoverInfo completion:(void (^)(NSString *password, NSError *error))callback {
    [self.master send:APIURLForgetPassword parameters:recoverInfo success:^(id responseObject) {
        if (callback) {
            callback(responseObject, nil);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (callback) {
            callback(nil, error);
        }
    } completion:nil];
}

#pragma mark -
- (void)fetchUserInformationCompletion:(void (^)(BOOL success, NSError *))callback {
    if (self.userID) {
        self.isFetchingUserInformation = YES;
        [self fetchUserInfoWithID:self.userID completion:^(UserInformation *info, NSError *error) {
            self.otherUserInformation = info;
            if (callback) {
                callback(YES, error);
            }
            self.isFetchingUserInformation = NO;
        }];
    }
    else {
        if (callback) {
            NSError __autoreleasing *e = [[NSError alloc] initWithDomain:@"this" code:0 userInfo:@{ NSLocalizedDescriptionKey : @"未登陆" }];
            callback(NO, e);
        }
    }
}

- (void)fetchUserInfoWithID:(int)userID completion:(void (^)(UserInformation *info, NSError *error))callback {
    [self.master fetch:APIURLUserInfo method:nil parameters:@{
        @"uid" : @(userID),
        @"token" : (self.token)? : @""
    } expectClass:[UserInformation class] success:^(id JSONModelObject) {
        if (callback) {
            callback(JSONModelObject, nil);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (callback) {
            callback(nil, error);
        }
    } completion:nil];
}

#pragma mark - Secret staues
- (void)loadProfileConfig {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    self.shouldRememberPassword = [ud boolForKey:UDkUserRemeberPass];
    self.shouldAutoLogin = [ud boolForKey:UDkUserAutoLogin];
    self.userAccount = [ud objectForKey:UDkLastUserAccount];
    
    if (self.shouldRememberPassword) {
#if APIUserPluginUsingKeychainToStroeSecret
        NSError __autoreleasing *e = nil;
        self.userPassword = [SSKeychain passwordForService:[NSBundle mainBundle].bundleIdentifier account:self.userAccount error:&e];
        if (e) dout_error(@"%@", e);
#else
        self.userPassword = [[NSUserDefaults standardUserDefaults] objectForKey:UDkUserPass];
#endif
    }
}

- (void)saveProfileConfig {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:self.userAccount forKey:UDkLastUserAccount];
    [ud setBool:self.shouldRememberPassword forKey:UDkUserRemeberPass];
    [ud setBool:self.shouldAutoLogin forKey:UDkUserAutoLogin];
    
#if APIUserPluginUsingKeychainToStroeSecret
    if (self.shouldRememberPassword) {
        NSError __autoreleasing *e = nil;
        [SSKeychain setPassword:self.userPassword forService:[NSBundle mainBundle].bundleIdentifier account:self.userAccount error:&e];
        if (e) dout_error(@"%@", e);
    }
    else {
        [SSKeychain deletePasswordForService:[NSBundle mainBundle].bundleIdentifier account:self.userAccount];
    }
#else
    if (self.shouldRememberPassword) {
        [ud setObject:self.userPassword forKey:UDkUserPass];
    }
    else {
        [ud removeObjectForKey:UDkUserPass];
    }
#endif
    
    [ud synchronize];
}

- (void)resetProfileConfig {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:NO forKey:UDkUserRemeberPass];
    [ud setBool:NO forKey:UDkUserAutoLogin];
    [ud setObject:@"" forKey:UDkUserPass];
    [ud setObject:@"" forKey:UDkLastUserAccount];
    [ud synchronize];
    
#if APIUserPluginUsingKeychainToStroeSecret
    [SSKeychain deletePasswordForService:[NSBundle mainBundle].bundleIdentifier account:self.userAccount];
#endif
}

@end
