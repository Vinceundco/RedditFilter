// AppLog.h
//
// A log you can read inside the app. A small "RF" button floats above every
// screen; it opens the log, which can be shared or copied. Meant for finding
// out what the login does on a device without a Mac. Never log passwords,
// cookie values, tokens or request bodies.

#import <Foundation/Foundation.h>

void RFAppLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Shows the floating button. Safe to call more than once.
void RFAppLogInstall(void);
