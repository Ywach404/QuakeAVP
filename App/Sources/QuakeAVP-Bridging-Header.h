//
//  QuakeAVP-Bridging-Header.h
//
//  QuakeCore.h is the entire C surface Swift is allowed to see; quakedef.h and
//  friends stay on the C side of the wall. QAVPExceptionShim is the one other
//  thing: an ObjC @try/@catch Swift cannot express itself.
//

#import "QuakeCore.h"
#import "QAVPExceptionShim.h"
