//
//  NSObject+IFACategory.h
//  IFACoreUI
//
//  Created by Marcelo Schroeder on 28/02/12.
//  Copyright (c) 2012 InfoAccent Pty Limited. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

@class NSPropertyDescription;

@interface NSObject (IFACoreUI)

/**
* Convenience method to return an image from the receiver's class bundle.
* @param a_imageName Name of the image to be returned.
* @returns Image from the receiver's class bundle.
*/
+ (UIImage *)ifa_classBundleImageNamed:(NSString *)a_imageName;

- (id)ifa_propertyValueForIndexPath:(NSIndexPath *)anIndexPath inForm:(NSString *)aFormName createMode:(BOOL)aCreateMode;
- (NSString*)ifa_propertyNameForIndexPath:(NSIndexPath *)anIndexPath inForm:(NSString *)aFormName createMode:(BOOL)aCreateMode;
- (NSString*)ifa_propertyStringValueForIndexPath:(NSIndexPath *)anIndexPath inForm:(NSString *)aFormName
                                      createMode:(BOOL)aCreateMode calendar:(NSCalendar*)a_calendar;

@end
