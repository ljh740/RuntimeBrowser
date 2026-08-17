/* 

ClassDisplay.h created by eepstein on Sun 17-Mar-2002

Author: Ezra Epstein (eepstein@prajna.com)

Copyright (c) 2002 by Prajna IT Consulting.
                      http://www.prajna.com

========================================================================

THIS PROGRAM AND THIS CODE COME WITH ABSOLUTELY NO WARRANTY.
THIS CODE HAS BEEN PROVIDED "AS IS" AND THE RESPONSIBILITY
FOR ITS OPERATIONS IS 100% YOURS.

========================================================================
This file is part of RuntimeBrowser.

RuntimeBrowser is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

RuntimeBrowser is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with RuntimeBrowser (in a file called "COPYING.txt"); if not,
write to the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
Boston, MA  02111-1307  USA

*/

#import <Foundation/Foundation.h>

// A decoded type, in two parts because of the C declaration syntax: the modifier follows the variable name,
// eg. "int " and "[10]" for int x[10], "unsigned int " and " : 3" for a bit field, "int (*" and ")()" for a function pointer.
@interface RTBTypeDeclaration : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *modifier; // never nil, empty when there is none
+ (instancetype)declarationWithType:(NSString *)type modifier:(NSString *)modifier;
@end

@interface RTBTypeDecoder : NSObject {
    const char* ivT; // the currently-processed Ivar type string
    BOOL currentWarning; // a warning was already issued while parsing the current type
}

@property (nonatomic) BOOL showCommentForBlocks;

// flat:YES for method arguments and return types, eg. "struct CGRect { ... }*"
// flat:NO for ivars, one struct member per line
+ (NSString *)decodeType:(NSString *)encodedType flat:(BOOL)flat;
+ (NSArray *)decodeTypes:(NSString *)encodedType flat:(BOOL)flat;

// full ivar declaration without the trailing semicolon, eg. "int _foo[10]", "int (*_callback)()", "unsigned int _flags : 3"
// encodedType may be nil (Swift-only types are not encoded), name may be nil (anonymous bit fields)
+ (NSString *)ivarDeclarationForEncodedType:(NSString *)encodedType name:(NSString *)name;

// for tests
- (RTBTypeDeclaration *)flatCTypeDeclForEncType:(const char*)encType;
- (RTBTypeDeclaration *)ivarCTypeDeclForEncType:(const char*)encType;

@end
