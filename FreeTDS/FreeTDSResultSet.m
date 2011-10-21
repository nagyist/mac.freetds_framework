//
//  FreeTDSResultSet.m
//  FreeTDS
//
//  Created by Daniel Parnell on 21/10/11.
//  Copyright (c) 2011 Automagic Software Pty Ltd. All rights reserved.
//

#import "FreeTDSResultSet.h"
#import "FreeTDS.h"
#import "FreeTDSResultSetMetadata.h"

@interface FreeTDS (Private)

- (void) checkForError;

@end

@implementation FreeTDSResultSet

- (id) initWithFreeTDS:(FreeTDS*)connection {
    self = [super init];
    
    if(self) {
        free_tds = connection;
    }
    
    return self;
}


#pragma mark -
#pragma mark Methods

- (FreeTDSResultSetMetadata*) getMetadata {
    return [[[FreeTDSResultSetMetadata alloc] initWithFreeTDS: free_tds] autorelease];
}

- (BOOL) next {
    BOOL result = dbnextrow(free_tds.process) != NO_MORE_ROWS;
    
    [free_tds checkForError];
    
    return result;
}

- (void) close {
    dbcancel([free_tds process]);
    [free_tds checkForError];
}

- (id) getObject:(int) index {
    int col = index + 1;
    DBPROCESS* process = free_tds.process;
    
    int coltype = dbcoltype(process, col);
    [free_tds checkForError];
    BYTE *data = dbdata(process, col);
    [free_tds checkForError];
    DBINT data_len = dbdatlen(process, col);
    [free_tds checkForError];
    
    id result;
    
    int null_val = ((data == NULL) && (data_len == 0));
    if (null_val) {
        result = [NSNull null];
    } else {
        switch(coltype) {
            case SYBINT1:
                result = [NSNumber numberWithInt: *(DBTINYINT *)data];
                break;
            case SYBINT2:
                result = [NSNumber numberWithInt: *(DBSMALLINT *)data];
                break;
            case SYBINT4:
                result = [NSNumber numberWithInt: *(DBINT *)data];
                break;
            case SYBINT8:
                result = [NSNumber numberWithLongLong: *(DBBIGINT *)data];
                break;
            case SYBBIT:
                result = [NSNumber numberWithBool: *(int *)data != 0];
                break;
            case SYBNUMERIC:
            case SYBDECIMAL: { 
                DBTYPEINFO *data_info = dbcoltypeinfo(process, col);
                [free_tds checkForError];
                int data_slength = (int)data_info->precision + (int)data_info->scale + 1;
                char converted_decimal[data_slength];
                dbconvert(process, coltype, data, data_len, SYBVARCHAR, (BYTE *)converted_decimal, -1);
                [free_tds checkForError];
                result = [NSDecimalNumber decimalNumberWithString: [NSString stringWithCString: &converted_decimal[0] encoding: NSUTF8StringEncoding]];
                break;
            }
            case SYBFLT8: {
                result = [NSNumber numberWithDouble: *(double *)data];
                break;
            }
            case SYBREAL: {
                result = [NSNumber numberWithFloat: *(float *)data];
                break;
            }
            case SYBMONEY: {
                DBMONEY *money = (DBMONEY *)data;
                long long money_value = ((long long)money->mnyhigh << 32) | money->mnylow;
                result = [[NSDecimalNumber decimalNumberWithString: [NSString stringWithFormat: @"%lld", money_value]] decimalNumberByMultiplyingByPowerOf10: -4];
                break;
            }
            case SYBMONEY4: {
                DBMONEY4 *money = (DBMONEY4 *)data;
                
                result = [NSNumber numberWithFloat: money->mny4 / 10000.0];
                break;
            }
            case SYBBINARY:
            case SYBIMAGE:
                result = [NSData dataWithBytes: data length: data_len];
                break;
            case 36: { // SYBUNIQUE
                char converted_unique[37];
                dbconvert(process, coltype, data, 37, SYBVARCHAR, (BYTE *)converted_unique, -1);
                result = [NSString stringWithCString: &converted_unique[0] encoding: NSUTF8StringEncoding];
                break;
            }
            case SYBDATETIME4: {
                DBDATETIME new_data;
                dbconvert(process, coltype, data, data_len, SYBDATETIME, (BYTE *)&new_data, sizeof(new_data));            
                data = (BYTE *)&new_data;
                data_len = sizeof(new_data);
            }
            case SYBDATETIME: {
                DBDATEREC date_rec;
                dbdatecrack(process, &date_rec, (DBDATETIME *)data);
                int year  = date_rec.dateyear,
                month = date_rec.datemonth+1,
                day   = date_rec.datedmonth,
                hour  = date_rec.datehour,
                min   = date_rec.dateminute,
                sec   = date_rec.datesecond,
                msec  = date_rec.datemsecond;
                if (year+month+day+hour+min+sec+msec != 0) {
                    uint64_t seconds = (year*31557600ULL) + (month*2592000ULL) + (day*86400ULL) + (hour*3600ULL) + (min*60ULL) + sec;
                    result = [NSDate dateWithTimeIntervalSince1970: seconds + msec / 1000.0];
                } else {
                    result = [NSNull null];
                }
                break;
            }
            case SYBCHAR:
            case SYBTEXT:
                result = [[NSString alloc] initWithBytes: data length: data_len encoding: NSUTF8StringEncoding];
                break;
            default:
                result = [[NSString alloc] initWithBytes: data length: data_len encoding: NSUTF8StringEncoding];
                break;
        }
    }

    return result;
}


@end
