/*
 This file is part of Darling.

 Copyright (C) 2020 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "IOService.h"
#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>
#include <cstring>

extern "C" {
#include "iokitmigServer.h"
}

IOService::IOService()
{

}

// Client matching is not personality matching. IOServiceMatching("Foo")
// is {IOProviderClass=Foo} and must match a service that *is* Foo
// (conformsTo), not a service whose boot personality named Foo as provider.
bool IOService::matches(NSDictionary* dict)
{
	for (NSString* key in dict)
	{
		NSObject* expectedValue = dict[key];

		if ([key isEqualToString: @"IOProviderClass"] || [key isEqualToString: @"IOClass"])
		{
			if (![expectedValue isKindOfClass: [NSString class]])
				return false;
			if (!conformsTo([(NSString*)expectedValue UTF8String]))
				return false;
			continue;
		}

		if ([key isEqualToString: @"IONameMatch"])
		{
			NSString* ourClass = [NSString stringWithUTF8String: className()];
			NSString* ourName = [NSString stringWithUTF8String: getName().c_str()];
			if ([expectedValue isKindOfClass: [NSArray class]])
			{
				NSArray* array = (NSArray*) expectedValue;
				if (![array containsObject: ourClass] && ![array containsObject: ourName])
					return false;
			}
			else if (![expectedValue isEqual: ourClass] && ![expectedValue isEqual: ourName])
				return false;
			continue;
		}

		NSDictionary* ourProps = matchingDictionary();
		NSObject* ourProp = ourProps[key];
		if (ourProp == nil)
			ourProp = getProperties()[key];

		if ([ourProp isKindOfClass: [NSArray class]])
		{
			NSArray* array = (NSArray*) ourProp;
			if (![array containsObject: expectedValue])
				return false;
		}
		else if (ourProp != nil)
		{
			if (![expectedValue isEqual: ourProp])
				return false;
		}
		else
			return false;
	}
	return true;
}

bool IOService::conformsTo(const char* className)
{
	if (strcmp(className, "IOService") == 0)
		return true;
	return IOObject::conformsTo(className);
}

kern_return_t is_io_service_get_state
(
	mach_port_t service,
	uint64_t *state,
	uint32_t *busy_state,
	uint64_t *accumulated_busy_time
)
{
    IOService* e = dynamic_cast<IOService*>(IOObject::lookup(service));
	if (!e)
		return kIOReturnBadArgument;

	*state = e->state();
	*busy_state = e->busyState();
	*accumulated_busy_time = e->accumulatedBusyTime();

    return kIOReturnSuccess;
}
