//
//  FreeTDS.m
//  FreeTDS
//
//  Created by Daniel Parnell on 19/10/11.
//  Copyright (c) 2011 Automagic Software Pty Ltd. All rights reserved.
//

#import "FreeTDS.h"

#define DEFAULT_PROTOCOL_VERSION 5

const NSString* FREETDS_SERVER = @"Server";
const NSString* FREETDS_USER = @"User";
const NSString* FREETDS_PASS = @"Password";
const NSString* FREETDS_DATABASE = @"Database";
const NSString* FREETDS_APPLICATION = @"Application";
const NSString* FREETDS_HOST = @"Host";
const NSString* FREETDS_PORT = @"Port";
const NSString* FREETDS_PROTOCOL_VERSION = @"Protocol Version";

const NSString* FREETDS_OS_ERROR = @"OS Error Description";
const NSString* FREETDS_OS_CODE = @"OS Error Code";
const NSString* FREETDS_DB_ERROR = @"Database Error";
const NSString* FREETDS_DB_CODE = @"Database Error Code";
const NSString* FREETDS_SEVERITY = @"Severity";
const NSString* FREETDS_MESSAGE = @"Message";
const NSString* FREETDS_MESSAGE_NUMBER = @"Message Number";
const NSString* FREETDS_MESSAGE_STATE = @"Message State";
const NSString* FREETDS_PROC_NAME = @"Procedure Name";
const NSString* FREETDS_LINE = @"Line";

const NSLock* login_lock = nil;

@interface FreeTDS (Private)

- (void) checkForError;
- (void) reset;

@end

@implementation FreeTDS

@synthesize login, process, delegate;


#pragma mark -
#pragma mark Error handlers

static NSException* login_exception = nil;

static id string_or_null(const char* s) {
    if(s) {
        return [NSString stringWithCString: s encoding: NSUTF8StringEncoding];
    }
    
    return [NSNull null];
}

static int err_handler(DBPROCESS *dbproc, int severity, int dberr, int oserr, char *dberrstr, char *oserrstr) {
    FreeTDS* free_tds = (FreeTDS*)dbgetuserdata(dbproc);
    
//    NSLog(@"err_handler: %p %d %d %d %s %s", dbproc, severity, dberr, oserr, dberrstr, oserrstr);
    
    int return_value = INT_CONTINUE;
    int cancel = 0;
    switch(dberr) {
        case 100: /* SYBEVERDOWN */
            return INT_CANCEL;
        case SYBESMSG:
            return return_value;
        case SYBEICONVI:
            return INT_CANCEL;
        case SYBEFCON:
        case SYBESOCK:
        case SYBECONN:
            return_value = INT_CANCEL;
            break;
        case SYBESEOF: {
            if (free_tds && free_tds->timing_out)
                return_value = INT_TIMEOUT;
            return INT_CANCEL;
            break;
        }
        case SYBETIME: {
            if (free_tds) {
                if (free_tds->timing_out) {
                    return INT_CONTINUE;
                } else {
                    free_tds->timing_out = YES;
                }
            }
            cancel = 1;
            break;
        }
        case SYBEWRIT: {
            if (free_tds && (free_tds->dbsqlok_sent || free_tds->dbcancel_sent))
                return INT_CANCEL;
            cancel = 1;
            break;
        }
        case SYBEREAD:
            cancel = 1;
            break;
    }
    
    NSException* ex = [NSException exceptionWithName: @"FreeTDS" 
                                              reason: [NSString stringWithFormat: @"%d - %s", dberr, dberrstr] 
                                            userInfo: [NSDictionary dictionaryWithObjectsAndKeys: 
                                                       string_or_null(oserrstr), FREETDS_OS_ERROR,
                                                       [NSNumber numberWithInt: oserr], FREETDS_OS_CODE,
                                                       string_or_null(dberrstr), FREETDS_DB_ERROR,
                                                       [NSNumber numberWithInt: dberr], FREETDS_DB_CODE,
                                                       [NSNumber numberWithInt: severity], FREETDS_SEVERITY,
                                                       nil]];
    
    if(free_tds) {
        free_tds->to_throw = ex;
    } else {
        login_exception = ex;
    }
    
    return return_value;
}

static int msg_handler(DBPROCESS *dbproc, DBINT msgno, int msgstate, int severity, char *msgtext, char *srvname, char *procname, int line) {
    FreeTDS* free_tds = (FreeTDS*)dbgetuserdata(dbproc);
    
    NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys: 
                          string_or_null(msgtext), FREETDS_MESSAGE,
                          [NSNumber numberWithInt: msgno], FREETDS_MESSAGE_NUMBER,
                          [NSNumber numberWithInt: msgstate], FREETDS_MESSAGE_STATE,
                          string_or_null(srvname), FREETDS_SERVER,
                          string_or_null(procname), FREETDS_PROC_NAME,
                          [NSNumber numberWithInt: line], FREETDS_LINE,
                          [NSNumber numberWithInt: severity], FREETDS_SEVERITY,
                          nil];
//    NSLog(@"info = %@", info);
    
    if(severity>10) {
        NSException* ex = [NSException exceptionWithName: @"FreeTDS" 
                                                  reason: [NSString stringWithFormat: @"%d - %s", msgno, msgtext] 
                                                userInfo: info];
        
        if(free_tds) {
            free_tds->to_throw = ex;
        } else {
            login_exception = ex;
        }        
    } else {
        if (free_tds && free_tds->delegate) {
            return [free_tds->delegate handleMessage: info withSeverity: severity from: free_tds];
        }
    }
    return  0;
}


#pragma mark -
#pragma mark Init and dealloc

+ (void) initialize {
    login_lock = [[NSLock new] retain];
}

+ (FreeTDS*) connectionWithDictionary:(NSDictionary*)dictionary {
    FreeTDS* result = [[FreeTDS new] autorelease];
    [result loginWithDictionary: dictionary];
    
    return result;
}

- (void)dealloc {
    [self close];
    
    [super dealloc];
}


#pragma mark -


- (void) loginWithDictionary:(NSDictionary*)dictionary {
    NSString* user = [dictionary objectForKey: FREETDS_USER];
    NSString* password = [dictionary objectForKey: FREETDS_PASS];
    NSString* server = [dictionary objectForKey: FREETDS_SERVER];
    NSString* database = [dictionary objectForKey: FREETDS_DATABASE];
    NSString* application = [dictionary objectForKey: FREETDS_APPLICATION];
    NSNumber* protocol = [dictionary objectForKey: FREETDS_PROTOCOL_VERSION];
    
    if(dbinit() == FAIL) {
        @throw [NSException exceptionWithName: @"FreeTDS" reason: NSLocalizedString(@"Could not initialize FreeTDS", @"dbinit failed") userInfo: nil];
    }
    dbsetifile((char *)[[[NSBundle bundleForClass: [FreeTDS class]] pathForResource: @"freetds" ofType: @"conf"] UTF8String]);
    
    dberrhandle(err_handler);
    dbmsghandle(msg_handler);
    
    login = dblogin();
    if(user) {
        dbsetluser(login, [user UTF8String]);
    }
    if(password) {
        dbsetlpwd(login, [password UTF8String]);
    }
    if(application) {
        dbsetlapp(login, [application UTF8String]);
    }
    if(protocol) {
        dbsetlversion(login, [protocol intValue]);
    } else {
        dbsetlversion(login, DEFAULT_PROTOCOL_VERSION);
    }
    
    if(server == nil) {
        NSString* host = [dictionary objectForKey: FREETDS_HOST];
        NSNumber* port = [dictionary objectForKey: FREETDS_PORT];

        if(port == nil) {
            server = [host stringByAppendingString: @":1433"];
        } else {
            server = [host stringByAppendingFormat: @":%d", [port intValue]];
        }
    }
    
    [login_lock lock];
    @try {
        login_exception = nil;
        process = dbopen(login, [server UTF8String]);
        if(login_exception) {
            @throw login_exception;
        }
    } @finally {
        login_exception = nil;
        [login_lock unlock];
    }
    
    if(process) {
        dbsetuserdata(process, (void*)self);
        
        if(database) {
            dbuse(process, [database UTF8String]);
            [self checkForError];
        }
    } else {
        @throw [NSException exceptionWithName: @"FreeTDS" reason: NSLocalizedString(@"Unknown login error", @"Unknown login error") userInfo: nil];
    }
}

- (void) close {
    if(login) {
        dbloginfree(login);
        login = nil;
    }
    if(process) {
        dbclose(process);
        process = nil;
    }
}

- (FreeTDSResultSet*) executeQuery:(NSString*) sql withParameters:(NSDictionary*)parameters {
    [self reset];
    dbcmd(process, [sql UTF8String]);
    [self checkForError];
    
    if (dbsqlsend(process) == FAIL) {
        @throw [NSException exceptionWithName: @"FreeTDS" reason: NSLocalizedString(@"dbsqlsend failed", @"dbsqlsend failed") userInfo: nil];
    }
    [self checkForError];
    
    return [[[FreeTDSResultSet alloc] initWithFreeTDS: self] autorelease];
}

#pragma mark -
#pragma mark Private stuff

- (void) checkForError {
    if (to_throw) {
        @try {
            @throw to_throw;
        }
        @finally {
            to_throw = nil;
        }
    }
}

- (void) reset {
    to_throw = nil;
    timing_out = NO;
    dbsqlok_sent = NO;
    dbcancel_sent = NO;    
}

@end
