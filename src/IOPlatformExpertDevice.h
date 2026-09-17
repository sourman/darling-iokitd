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

#ifndef IOKITD_IOPLATFORMEXPERTDEVICE_H
#define IOKITD_IOPLATFORMEXPERTDEVICE_H

#include "IOService.h"
#include "ServiceRegistry.h"

// macOS always publishes this nub at the root of IOService. User clients
// (including Chromium) look it up with IOServiceMatching("IOPlatformExpertDevice").
class IOPlatformExpertDevice : public IOService
{
public:
	const char* className() const override;
	NSDictionary* matchingDictionary() override;
	NSDictionary* getProperties() override;
	bool conformsTo(const char* className) override;

	static IOPlatformExpertDevice* instance();
	static void registerSelf(ServiceRegistry* targetServiceRegistry);
};

// Live nubs for Chromium IOServiceMatching lookups that iokitd did not
// previously publish (IOPMPowerSource / IOFramebuffer / AppleBacklight / AppleSMC / …).
void publishChromeIOKitServices(ServiceRegistry* targetServiceRegistry);

#endif
