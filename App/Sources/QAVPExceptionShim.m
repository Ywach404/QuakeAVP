// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez

#import "QAVPExceptionShim.h"

BOOL QAVPTry(void (NS_NOESCAPE ^block)(void), NSString * _Nullable * _Nullable reason)
{
	@try {
		block();
		return YES;
	}
	@catch (NSException *e) {
		if (reason) {
			*reason = e.reason ?: e.name;
		}
		return NO;
	}
}
