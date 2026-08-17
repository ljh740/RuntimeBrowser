/*
 
 ClassDisplay.m created by eepstein on Sun 17-Mar-2002
 
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

/*
 Type encodings handled here, see
 https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
 and clang's ASTContext::getObjCEncodingForTypeImpl().

 Modern additions:
 - block signatures in extended type encodings, eg. @?<v@?@"NSError"> -> void (^)(NSError *)
 - protocol-qualified objects, eg. @"<NSCopying><NSCoding>" -> id <NSCopying, NSCoding>
 - __int128 't' and unsigned __int128 'T'
 - _Atomic 'A', _Complex 'j', long double 'D'
 - types clang cannot encode (eg. vector types) are simply left out by the compiler,
   which yields empty types such as [3], ^96 or {?="v"} -> "void" followed by a "?" comment

 The parser is a recursive descent over ivT, the encoding being parsed. A decoded type comes in two
 parts, see RTBTypeDeclaration. The nested structs get generated member names, eg. x1, x_1_2_1.
 */

#import "RTBTypeDecoder.h"

#if (! TARGET_OS_IPHONE)
#import <objc/objc-runtime.h>
#else
#import <objc/runtime.h>
#import <objc/message.h>
#endif

static NSString *IVAR_TAB = @"    ";

#define isTypeSpecifier(fc) (fc=='r'||fc=='R'||fc=='n'||fc=='N'||fc=='o'||fc=='O'||fc=='V'||fc=='A'||fc=='j'||fc=='!')

NSString * rtb_argTypeSpecifierForEncoding(char fc) {
    if(fc == 'r') return @"const ";
    if(fc == 'R') return @"byref ";
    if(fc == 'n') return @"in ";
    if(fc == 'N') return @"inout ";
    if(fc == 'o') return @"out ";
    if(fc == 'O') return @"bycopy ";
    if(fc == 'V') return @"oneway ";
    if(fc == 'A') return @"_Atomic ";
    if(fc == 'j') return @"_Complex ";
    if(fc == '!') return @""; // garbage-collector marked invisible -> ignore
    return nil;
}

@interface RTBTypeDecoder ()
- (NSString *)parseStructOrUnionEndCh:(char)endCh depth:(int *)depth sPart:(int)sPart inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter;
- (RTBTypeDeclaration *)typeEncParseObjectRefInStruct:(BOOL)inStruct mayHaveClassName:(BOOL)mayHaveClassName spaceAfter:(BOOL)spaceAfter;
- (RTBTypeDeclaration *)cTypeDeclForEncTypeDepth:(int *)depth sPart:(int)sPart inStruct:(BOOL)inStruct inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter;
- (RTBTypeDeclaration *)cTypeDeclForEncTypeDepth:(int *)depth sPart:(int)sPart inStruct:(BOOL)inStruct mayHaveClassName:(BOOL)mayHaveClassName inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter;
@end

@implementation RTBTypeDeclaration

+ (instancetype)declarationWithType:(NSString *)type modifier:(NSString *)modifier {
    RTBTypeDeclaration *d = [[self alloc] init];
    d.type = type;
    d.modifier = modifier ? modifier : @"";
    return d;
}

@end

// the type used when the compiler did not encode a type at all (eg. vector types)
static NSString *RTB_UNKNOWN_TYPE = @"void /* ? */";

static BOOL rtb_isTypeTerminator(char c) {
    // characters that can follow a type, ie. that cannot start one
    return c == '\0' || isdigit(c) || c == '}' || c == ')' || c == ']' || c == '"' || c == '>';
}

// The name of a struct or union may be a C++ template name with nested angle brackets, parentheses,
// spaces and commas, eg. {function<bool (unsigned long long)>={...}} or {vector<CGPoint, std::allocator<CGPoint>>=...}
// Returns a pointer to the '=' that separates the name from the definition, or NULL if there is no definition (name only).
static const char *rtb_structDefinitionStart(const char *p, char endCh) {
    int angleDepth = 0;
    for (; *p != '\0'; ++p) {
        if (*p == '<') {
            ++angleDepth;
        } else if (*p == '>') {
            if (angleDepth > 0) --angleDepth;
        } else if (angleDepth == 0) {
            if (*p == '=') return p;
            if (*p == endCh || *p == '{' || *p == '(' || *p == '"') return NULL;
        }
    }
    return NULL;
}

// Returns a pointer to the endCh closing a name-only struct or union, skipping the characters nested in angle brackets.
static const char *rtb_structNameEnd(const char *p, char endCh) {
    int angleDepth = 0;
    for (; *p != '\0'; ++p) {
        if (*p == '<') {
            ++angleDepth;
        } else if (*p == '>') {
            if (angleDepth > 0) --angleDepth;
        } else if (angleDepth == 0 && *p == endCh) {
            return p;
        }
    }
    return NULL;
}

@implementation RTBTypeDecoder

- (void)setIvT:(const char*)s {
    ivT = s;
}

- (const char*)ivT {
    return ivT;
}

+ (NSArray *)decodeTypes:(NSString *)encodedTypes flat:(BOOL)flat {
    
    // no cache here: the decoders are used from several threads (search, embedded web server) and the results are cheap
    
    NSMutableArray *ma = [NSMutableArray array];

    const char *cString = [encodedTypes cStringUsingEncoding:NSUTF8StringEncoding];
    if(cString == NULL) return ma; // nil or non UTF-8 encoding
    
    RTBTypeDecoder *typeDecoder = [[self alloc] init];
    typeDecoder.showCommentForBlocks = [[NSUserDefaults standardUserDefaults] boolForKey:@"RTBAddCommentsForBlocks"];
    
    [typeDecoder setIvT:cString];
    
    if(isdigit(*cString)) {
        // A method type encoding starting with digits has an empty return type, eg. 16@0:8 for a simd return type.
        // The other empty types cannot be recovered since their offsets get merged with the previous ones, eg. v32@0:816
        [ma addObject:RTB_UNKNOWN_TYPE];
    }
    
    while(YES) {
        @autoreleasepool {
  
        RTBTypeDeclaration *d = nil;
        
        [typeDecoder skipDigits];

        //printf("--> %s\n", typeDecoder.ivT);
        
        if(strlen(typeDecoder.ivT) == 0) break;
        
        if(flat) {
            d = [typeDecoder flatCTypeDeclForEncType];
        } else {
            d = [typeDecoder ivarCTypeDeclForEncType];
        }

        NSString *type = d.type;
        NSString *modifier = d.modifier;
            
        if(flat && [modifier length] > 0) {
            // there is no variable name to put in between, eg. "int (*" + ")()" -> "int (*)()"
            type = [type stringByAppendingString:modifier];
        }
            
        [ma addObject:type];
            
        }
    }
    
    return ma;
}

+ (NSString *)ivarDeclarationForEncodedType:(NSString *)encodedType name:(NSString *)name {
    
    // eg. "int _foo[10]", "unsigned int _flags : 3", "int (*_callback)()", "NSString * _name"
    
    if(name == nil) name = @"/* ? */"; // the compiler may generate ivar entries with a NULL name (eg. for anonymous bit fields)
    
    const char *cString = [encodedType cStringUsingEncoding:NSUTF8StringEncoding];
    if(cString == NULL || strlen(cString) == 0) {
        // no type encoding at all, this happens with Swift-only types
        return [NSString stringWithFormat:@"%@ %@", RTB_UNKNOWN_TYPE, name];
    }
    
    RTBTypeDecoder *typeDecoder = [[self alloc] init];
    typeDecoder.showCommentForBlocks = [[NSUserDefaults standardUserDefaults] boolForKey:@"RTBAddCommentsForBlocks"];
    
    RTBTypeDeclaration *d = [typeDecoder ivarCTypeDeclForEncType:cString];
    NSString *type = d.type;
    NSString *modifier = d.modifier;
    
    if(type == nil) return [NSString stringWithFormat:@"%@ %@", RTB_UNKNOWN_TYPE, name];
    
    NSString *separator = [type hasSuffix:@"(*"] ? @"" : @" "; // int (*_callback)()
    
    return [NSString stringWithFormat:@"%@%@%@%@", type, separator, name, modifier ? modifier : @""];
}

+ (NSString *)decodeType:(NSString *)encodedType flat:(BOOL)flat {
    
    NSArray *types = [self decodeTypes:encodedType flat:flat];
    if([types count] == 0) {
        // nil, empty or digits-only encoding, eg. a return type the compiler could not encode
        return RTB_UNKNOWN_TYPE;
    }
    NSAssert([types count] > 0, nil);
    NSString *decodedType = types[0];
    
    return decodedType;
}

- (RTBTypeDeclaration *)typeEncWarning:(NSString *)inParse startingIVT:(const char*)startingIVT origResult:(RTBTypeDeclaration *)origResult {
    NSString *typeS = origResult.type;
    NSString *modifierS = origResult.modifier;
    
    typeS = [NSString stringWithFormat:@"/* Warning: unhandled %@encoding: '%s' */ %@", inParse, startingIVT, typeS];
    currentWarning = YES;  // indicated that we've already issued a warning on this pass through the ivar parser.
    
    return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
}

// See the "Definitions of filer types" #define(s) in objc-class.h
- (NSString *)typeForFilerCode:(char)fc spaceAfter:(BOOL)spaceAfter {
    NSString *rs;
    
    /*
     #define _C_ID       '@'
     #define _C_CLASS    '#'
     #define _C_SEL      ':'
     #define _C_CHR      'c'
     #define _C_UCHR     'C'
     #define _C_SHT      's'
     #define _C_USHT     'S'
     #define _C_INT      'i'
     #define _C_UINT     'I'
     #define _C_LNG      'l'
     #define _C_ULNG     'L'
     #define _C_LNG_LNG  'q'
     #define _C_ULNG_LNG 'Q'
     #define _C_FLT      'f'
     #define _C_DBL      'd'
     #define _C_BFLD     'b'
     #define _C_BOOL     'B'
     #define _C_VOID     'v'
     #define _C_UNDEF    '?'
     #define _C_PTR      '^'
     #define _C_CHARPTR  '*'
     #define _C_ATOM     '%'
     #define _C_ARY_B    '['
     #define _C_ARY_E    ']'
     #define _C_UNION_B  '('
     #define _C_UNION_E  ')'
     #define _C_STRUCT_B '{'
     #define _C_STRUCT_E '}'
     #define _C_VECTOR   '!'
     #define _C_CONST    'r'
     
     Not in the old headers but emitted by clang:
     'D' long double, 't' __int128, 'T' unsigned __int128, 'A' _Atomic, 'j' _Complex
     */
    
    switch (fc) {
        case '@' :
            rs = @"id";
            break;
        case '#' :
            rs = @"Class";
            break;
        case ':' :
            rs = @"SEL";
            break;
        case 'c' :
#if OBJC_BOOL_IS_BOOL
            rs = @"char"; // BOOL is bool on this platform, a signed char is a char
#else
            rs = @"BOOL"; // BOOL is a signed char on this platform, and far more common than char
#endif
            break;
        case 'C' :
            rs = @"unsigned char";
            break;
        case 's' :
            rs = @"short";
            break;
        case 'S' :
            rs = @"unsigned short";
            break;
        case 'i' :
            rs = @"int";
            break;
        case 'I' :
            rs = @"unsigned int";
            break;
        case 'l' :
            rs = @"long";
            break;
        case 'L' :
            rs = @"unsigned long";
            break;
        case 'q' :
            rs = @"long long";
            break;
        case 'Q' :
            rs = @"unsigned long long";
            break;
        case 'f' :
            rs = @"float";
            break;
        case 'd' :
            rs = @"double";
            break;
        case 'D':
            rs = @"long double";
            break;
        case 't' :
            rs = @"__int128";
            break;
        case 'T' :
            rs = @"unsigned __int128";
            break;
        case 'B' :
#if OBJC_BOOL_IS_BOOL
            rs = @"BOOL"; // arm64: BOOL is bool
#else
            rs = @"bool";
#endif
            break;
        case 'v' :
            rs = @"void";
            break;
        case '*' : // STR
        case '%' : // _C_ATOM
            rs = @"char *";
            break;
        case ' ' : // clang encodes the builtin types it has no encoding for as a space, eg. _Float16
            rs = RTB_UNKNOWN_TYPE;
            break;
        default :
            if (!currentWarning) {
                currentWarning = YES;
                rs = [NSString stringWithFormat:@"/* Warning: Unrecognized filer type: '%c' using 'void*' */ void*", fc];
            } else {
                rs = @"void*";
            }
            break;
    }
    
    if (spaceAfter) {
        switch (fc) {
            case '@' : case '#' : case ':' : case 'c' : case 'C' :
            case 's' : case 'S' : case 'i' : case 'I' : case 'l' : case 'L' : case 'q' : case 'Q' :
            case 'f' : case 'd' : case 'D' : case 't' : case 'T' : case 'v' : case 'B': case ' ':
                rs = [rs stringByAppendingString:@" "];
                break;
        }
    }
    
    return rs;
}

- (RTBTypeDeclaration *)typeEncParseBitField:(BOOL)spaceAfter {
    /*"
     NeXT: bit field encoding format 'bN', where N is the size, an integer.
     Later GCC: encoding format 'bOtN',  where O (an int) is the offset, t (char) is the type, N (int) is the size.
     "*/
    RTBTypeDeclaration *result;
    NSString *typeS = nil;
    NSString *modifierS = nil;
    int sizeModifier;    // size of this bitfield
    
    /* PENDING PENDING
     position = atoi (type + 1);
     while (isdigit (*++type));
     
     size = atoi (type + 1);
     
     startByte = position / BITS_PER_UNIT;
     endByte = (position + size) / BITS_PER_UNIT;
     return endByte - startByte;
     */
    
    if (sscanf(ivT, "%d", &sizeModifier) == 1) {  // parse the integer
        while (isdigit(*++ivT));       // skip the digits
        modifierS = [NSString stringWithFormat:@" : %d", sizeModifier]; // its a size modifier
        typeS = (spaceAfter ? @"unsigned int " : @"unsigned int"); // bit fields use unsigned int
        result = [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
    } else {  // warn about badly formatted FILER type info.
        typeS = (spaceAfter ? @"unsigned int " : @"unsigned int");
        modifierS = @"/* : ? */";
        result = [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
        if (!currentWarning)
            result = [self typeEncWarning:@"bit field" startingIVT:(ivT - 1) origResult:result];
        // to skip the rest, or not to skip ...
        // ivT += strlen(ivT);
    }
    return result;
}

- (BOOL)hasClassName {
    // An object pointer (type 'id') includes a
    // named reference iff the following name is quoted.
    // Inside a struct, the quotes would be nested,
    // so we make sure the name is double-quoted before
    // we use it as a class name (e.g., NSObject *) -- otherwise
    // it's the variable name.
    // The class name is followed by the next field name, or by the end of the
    // enclosing struct, union or array, eg. {?="a"@"NSString""b"i}, (?="a"@"NSString"), [2@"NSString"]
    const char *tmp = strchr(ivT+1, '"');
    return ((tmp != NULL) && (*(tmp+1) == '"' || *(tmp+1) == '}' || *(tmp+1) == ')' || *(tmp+1) == ']'));
}

- (void)advanceIVTPast:(char)endCh {
    /**
     Advance ivT past endCh or, if not found, to the end of ivT.
     This is called after a parse "error" (no endCh at expected location).
     */
    const char* tmp = strchr(ivT, endCh);
    if (tmp == NULL)
        ivT += strlen(ivT);  // can't find endCh, move to the end of the string.
    else
        ivT = tmp + 1;       // move past endCh
}

- (RTBTypeDeclaration *)typeEncParseArrayOf:(int *)depth sPart:(int)sPart inStruct:(BOOL)inStruct mayHaveClassName:(BOOL)mayHaveClassName inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter {
    NSString *typeS = nil;
    NSString *modifierS = nil;
    int sizeModifier;    // size of this array
    
    if (sscanf(ivT, "%d", &sizeModifier) == 1) {  // Array encoding starts with the size of the array
        RTBTypeDeclaration *innerTypeInfo;
        
        while (isdigit(*ivT)) ++ivT;      // move past the digits (size)
        if (*ivT == ']') {
            // the compiler did not encode the element type, eg. [3] for an array of vectors
            typeS = spaceAfter ? [RTB_UNKNOWN_TYPE stringByAppendingString:@" "] : RTB_UNKNOWN_TYPE;
            modifierS = [NSString stringWithFormat:@"[%d]", sizeModifier];
            return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
        }
        innerTypeInfo = [self cTypeDeclForEncTypeDepth:depth sPart:sPart inStruct:inStruct mayHaveClassName:mayHaveClassName inLine:inLine spaceAfter:spaceAfter]; // what TYPE of array
        typeS = innerTypeInfo.type;  // get the inner type
        // append a modifier that makes the type into an array of size 'sizeModifier'
        // NOTE: the array itself may be "modified" (e.g., nested arrays),  so append the inner modifier.
        modifierS = [NSString stringWithFormat:@"[%d]%@", sizeModifier, innerTypeInfo.modifier];
    } else {  // no size encoded ... handle bad or unrecognized encodings
        if (!currentWarning) {
            currentWarning = YES;
            typeS = [NSString stringWithFormat:@"/* Warning: unhandled array encoding: '%s' */void*", (ivT - 1)];
            if (spaceAfter) typeS = [typeS stringByAppendingString:@" "];
        } else {
            typeS = (spaceAfter ? @"void* " : @"void*");
        }
        modifierS = @"[ /* ? */ ]"; // size unknown.
    }
    
    return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
}

- (RTBTypeDeclaration *)typeEncParsePointerTo:(int *)depth sPart:(int)sPart inStruct:(BOOL)inStruct inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter {
    NSString *typeS = nil;
    NSString *modifierS = nil;
    
    if (*ivT == '?') { // function pointer
        ++ivT;
        typeS = @"int (*";
        modifierS = @")()";
    } else if (rtb_isTypeTerminator(*ivT)) {
        // the compiler did not encode the pointee type, eg. ^96 for a pointer to a vector type followed by its offset
        typeS = [RTB_UNKNOWN_TYPE stringByAppendingString:@" *"];
        modifierS = @"";
    } else {
        // Note that clang never encodes class names after a pointer, eg. NSError ** is ^@ and not ^@"NSError",
        // so a quoted string here is always the name of the next field of the enclosing struct.
        RTBTypeDeclaration *innerTypeInfo = [self cTypeDeclForEncTypeDepth:depth sPart:sPart inStruct:inStruct mayHaveClassName:NO inLine:inLine spaceAfter:spaceAfter]; // Get the type
        
        modifierS = innerTypeInfo.modifier;  // and it's modifier
        NSString *innerType = innerTypeInfo.type;
        BOOL needsSpace = [innerType length] > 0 && [innerType hasSuffix:@" "] == NO && [innerType hasSuffix:@"*"] == NO; // void * and void **, int (**)()
        typeS = [innerType stringByAppendingString:(needsSpace ? @" *" : @"*")];  // make type a pointer
    }
    
    return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
}

- (void)skipDigits {
    while (strlen(ivT) && isdigit (*ivT)) {
        ivT++;
    };
}

- (RTBTypeDeclaration *)flatCTypeDeclForEncType {
    int depth = 0;
    return [self cTypeDeclForEncTypeDepth:&depth sPart:0 inStruct:NO inLine:YES spaceAfter:NO];
}

- (RTBTypeDeclaration *)ivarCTypeDeclForEncType {
    int depth = 0;
    return [self cTypeDeclForEncTypeDepth:&depth sPart:0 inStruct:NO inLine:NO spaceAfter:YES];
}

- (NSMutableString *)parseUnnamedStructOrUnionVarEndCh:(char)endCh depth:(int *)depth sPart:(int)sPart inLine:(BOOL)inLine {
    NSMutableString *structS = [NSMutableString string];
    RTBTypeDeclaration *structInfo;
    NSString *partName;
    int i;
    
    //parse each char as an (unnamed) type ... we then need to assign names.
    for (i=1; *ivT != endCh && *ivT != '\0'; ++i) {
        @autoreleasepool {
            
            structInfo = [self cTypeDeclForEncTypeDepth:depth sPart:i inStruct:YES inLine:inLine spaceAfter:YES];
            
            // Naming for nested pieces is a bit of a kludge.
            // To support arbitrary nesting w/ unique naming (not required to compile)
            // we'd need an array of sPart[] and increment sPart[depth] and output
            // all sParts in sequence to generate a unique name (based on location)
            
            if ([structS length] > 1024) {
                continue;
            }
            
            if (sPart > 1 || *depth > 1) {
                partName = [NSString stringWithFormat:@"x_%d_%d_%d", sPart, (*depth)-1, i];
            } else {
                partName = [NSString stringWithFormat:@"x%d", i];
            }
            [structS appendString:structInfo.type];
            [structS appendString:partName];
            [structS appendString:structInfo.modifier];
            [structS appendString:@"; "];
        }
    }
    
    return structS;
}

- (RTBTypeDeclaration *)typeEncParseStructOrUnionWithEncType:(NSString *)encType endCh:(char)endCh depth:(int *)depth sPart:(int)sPart inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter {
    
    NSString *typeS = @"";
    NSString *modifierS = @"";
    const char *eqPos = rtb_structDefinitionStart(ivT, endCh);
    
    ++(*depth);
    // Check for a definition (after an '=') within this (possibly nested) struct/union (e.g., before endCh).
    // The '=' must come before the end of this struct/union and before the beginning of another.
    if ( eqPos != NULL ) {
        // struct or union definition provided (parsed by parseStructOrUnion()).
        typeS = [self parseStructOrUnionEndCh:endCh depth:depth sPart:sPart inLine:inLine spaceAfter:spaceAfter];
    } else {   // named struct or union (name only)
        const char *tmp = rtb_structNameEnd(ivT, endCh);
        if (tmp != NULL) {
            
            if (*ivT != '?') {
                
                // A union without '=' may be a name only, eg. (Foo) like a pointee struct {Foo}, or old-style unnamed types
                BOOL isNameOnly = YES;
                for (const char *c = ivT; c < tmp; ++c) {
                    if (!(isalnum(*c) || *c == '_' || *c == '<' || *c == '>' || *c == ':' || *c == ',' || *c == ' ' || *c == '*' || *c == '&' || *c == '(' || *c == ')' || *c == '[' || *c == ']')) { isNameOnly = NO; break; }
                }
                
                // need parse union's differently
                if (endCh == ')' && !isNameOnly) {  // Learned this later... no longer a generic Struct/Unin parser. Alas.
                    typeS =  [self parseUnnamedStructOrUnionVarEndCh:endCh depth:depth sPart:sPart inLine:inLine];
                                    typeS = [NSString stringWithFormat:@"{ %@} ", typeS];
                } else {
                    typeS = [[NSString alloc] initWithBytes:ivT length:tmp-ivT encoding:NSUTF8StringEncoding];
                    if (typeS == nil) typeS = @"";
                    if (spaceAfter)
                        typeS = [typeS stringByAppendingString:@" {} "];
                    else
                        typeS = [typeS stringByAppendingString:@" {}"];
                }
                
            } else {
                typeS = (spaceAfter ? @"{ /* ? */ } " : @"{ /* ? */ }");
            }
            
            ivT = tmp;
        }
    }
    
    if(typeS != nil) {
        typeS = [encType stringByAppendingString:typeS];
    } else {
        typeS = encType;
    }
    --(*depth);
    
    return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
}

- (NSString *)parseStructOrUnionEndCh:(char)endCh depth:(int *)depth sPart:(int)sPart inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter {
    RTBTypeDeclaration *structInfo;
    NSMutableString *structS;
    NSMutableString *depthS = (NSMutableString *)@"";
    NSString *name = nil;
    NSString *partName = nil;
    NSString *fmt1 = (spaceAfter ? @"{ %@%@} " : @"{ %@%@}");    // no space (' ') after decl for parameter)s.
    NSString *fmt2 = (spaceAfter ? @" { %@%@} " : @" { %@%@}");
    int i;
    
    const char *tmp = rtb_structDefinitionStart(ivT, endCh);
    NSAssert(tmp != NULL, @"struct or union definition expected"); // the caller checked
    
    if (*ivT != '?') {
        name = [[NSString alloc] initWithBytes:ivT length:tmp-ivT encoding:NSUTF8StringEncoding]; // get the name
    }
    
    ivT = tmp + 1;
    
    if (*ivT == '"') {
        structS = [NSMutableString string];
        while (*ivT == '"') {
            ++ivT;
            tmp = strchr(ivT, '"');
            
            if (tmp == NULL) { // no closing quote, give up on this struct and let the caller consume endCh
                const char *end = strchr(ivT, endCh);
                ivT = end ? end : ivT + strlen(ivT);
                break;
            }
            
            partName = [[NSString alloc] initWithBytes:ivT length:tmp-ivT encoding:NSUTF8StringEncoding]; // get the name
            
            ivT = tmp + 1;
            
            if (*ivT == '"' || *ivT == endCh) {
                // the compiler did not encode the type of this field, eg. {?="f"f"v"} where v is a vector
                structInfo = [RTBTypeDeclaration declarationWithType:[RTB_UNKNOWN_TYPE stringByAppendingString:@" "] modifier:@""];
            } else {
                structInfo = [self cTypeDeclForEncTypeDepth:depth sPart:sPart inStruct:YES inLine:inLine spaceAfter:YES];
            }
            
            if (!inLine) {
                depthS = [NSMutableString string];
                for (i=0; i<*depth; ++i)
                    [depthS appendString:IVAR_TAB];
                [structS appendFormat:@"\n%@", IVAR_TAB];
                [structS appendString:depthS];
            }
            [structS appendString:structInfo.type];
            [structS appendString:partName];
            [structS appendString:structInfo.modifier];
            [structS appendString:@"; "];
        }
        if (!inLine)
            [structS appendString:@"\n"];
    } else {  // unnamed members
        structS = [self parseUnnamedStructOrUnionVarEndCh:endCh depth:depth sPart:sPart inLine:inLine];
    }
    
    if (name == nil) return [NSString stringWithFormat:fmt1, structS, depthS];
    return [name stringByAppendingFormat:fmt2, structS, depthS];
}

// uses the global ivT
// depth -- how deeply nested a struct or union is
// sPart -- which part of an outer struct we're in.
- (RTBTypeDeclaration *)cTypeDeclForEncTypeDepth:(int *)depth sPart:(int)sPart inStruct:(BOOL)inStruct inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter {
    return [self cTypeDeclForEncTypeDepth:depth sPart:sPart inStruct:inStruct mayHaveClassName:YES inLine:inLine spaceAfter:spaceAfter];
}

// mayHaveClassName -- NO when a quoted string cannot be a class name, ie. after a pointer
- (RTBTypeDeclaration *)cTypeDeclForEncTypeDepth:(int *)depth sPart:(int)sPart inStruct:(BOOL)inStruct mayHaveClassName:(BOOL)mayHaveClassName inLine:(BOOL)inLine spaceAfter:(BOOL)spaceAfter {
    /*"
     This is the entry point for parsing encoded ivar types.
     "*/
    RTBTypeDeclaration *result;
    NSString *type = nil;
    NSString *modifier = nil;
    NSString *typeSpec = nil;
    const char *startingIVT = ivT;  // used in "Warning" string
    char closingChar = '\0';        // for array, struct and union (null ('\0') for all else)
    NSString *parsedTypeName = nil; // one of: @"array", @"struct", @"union" or nil
        
    switch (*ivT) {  // what sort of thing are we parsing
        case '!' :   // "weak" pointer specifier (for new Garbage collection...).
            ++ivT; // '!' indicates a runtime (non-declarative) feature, skip it and continue
            result = [self cTypeDeclForEncTypeDepth:depth sPart:sPart inStruct:inStruct mayHaveClassName:mayHaveClassName inLine:inLine spaceAfter:spaceAfter];
            break;
        case '^' :   // Pointer to another type.
            ++ivT;
            result = [self typeEncParsePointerTo:depth sPart:sPart inStruct:inStruct inLine:inLine spaceAfter:spaceAfter];
            break;
        case 'b' :   // bit field
            ++ivT;
            result = [self typeEncParseBitField:spaceAfter];
            break;
        case '@' :   // id or id? (block) or named object reference
            ++ivT;
            result = [self typeEncParseObjectRefInStruct:inStruct mayHaveClassName:mayHaveClassName spaceAfter:spaceAfter];
            break;
        case '[' :   // array
            ++ivT;
            result = [self typeEncParseArrayOf:depth sPart:sPart inStruct:inStruct mayHaveClassName:mayHaveClassName inLine:inLine spaceAfter:spaceAfter];
            
            closingChar = ']';  parsedTypeName = @"array ";
            break;
        case '{' :   // struct
            ++ivT;
            closingChar = '}';  parsedTypeName = @"struct ";
            result = [self typeEncParseStructOrUnionWithEncType:parsedTypeName endCh:closingChar depth:depth sPart:sPart inLine:inLine spaceAfter:spaceAfter];
            break;
        case '(' :   // union -- version for Yellow Box from WO 4.5, may need fixing.
            ++ivT;
            closingChar = ')';  parsedTypeName = @"union ";
            result = [self typeEncParseStructOrUnionWithEncType:parsedTypeName endCh:closingChar depth:depth sPart:sPart inLine:inLine spaceAfter:spaceAfter];
            break;
        default :    // a simple type or starts with a type specifier
            while (isTypeSpecifier(*ivT)) {  // prepend type specifier(s)
                if (typeSpec == nil) typeSpec = @"";
                typeSpec = [typeSpec stringByAppendingString:rtb_argTypeSpecifierForEncoding(*ivT)];
                ++ivT;
            }
            
            if (typeSpec == nil) { // most common case: types are NOT modified by a specifier
                
                type = [self typeForFilerCode:*ivT spaceAfter:spaceAfter];
                modifier = @"";
                ++ivT;
            } else if (rtb_isTypeTerminator(*ivT)) {
                // a type specifier with no type after it, eg. r16 for a const vector type
                type = [typeSpec stringByAppendingString:(spaceAfter ? [RTB_UNKNOWN_TYPE stringByAppendingString:@" "] : RTB_UNKNOWN_TYPE)];
                modifier = @"";
            } else {
                result = [self cTypeDeclForEncTypeDepth:depth sPart:sPart inStruct:inStruct mayHaveClassName:mayHaveClassName inLine:inLine spaceAfter:spaceAfter];
                type = [typeSpec stringByAppendingString:result.type];
                modifier =result.modifier;
            }
            result = [RTBTypeDeclaration declarationWithType:type modifier:modifier];
            break;
    }
    if (closingChar != '\0') {
        if (*ivT == closingChar) {  // Properly closed array, struct or union
            ++ivT;
        } else {            // handle bad or unrecognized encodings
            if (!currentWarning) // if we haven't already, include a warning...
                result = [self typeEncWarning:parsedTypeName startingIVT:startingIVT origResult:result];
            [self advanceIVTPast:closingChar];
        }
    }
    
    return result;
}

+ (NSString *)objectTypeForQuotedName:(NSString *)name {
    /*"
     The quoted name after '@' is a class name, optionally followed by protocols, or protocols only:
       "NSString"                     -> NSString *
       "NSObject<NSCopying><NSCoding>" -> NSObject<NSCopying, NSCoding> *
       "<NSCopying><NSCoding>"         -> id <NSCopying, NSCoding>
     "*/
    NSString *s = [name stringByReplacingOccurrencesOfString:@"><" withString:@", "];
    if ([s hasPrefix:@"<"]) {
        return [@"id " stringByAppendingString:s];
    }
    return [s stringByAppendingString:@" *"];  // And, of course, id is a pointer to a class reference.
}

- (NSString *)parseBlockSignature {
    /*"
     Extended type encodings, as found in protocol method descriptions, contain the block signature
     between angle brackets, eg. @?<v@?@"NSData"@"NSError"> for void (^)(NSData *, NSError *).
     The first type is the return type, the second one is the block itself, then come the arguments.
     ivT points at the opening '<'. Returns nil and leaves ivT unchanged if the signature is not well-formed.
     "*/
    NSAssert(*ivT == '<', @"");
    
    const char *p = ivT + 1;
    int angleDepth = 1;
    while (*p != '\0') {
        if (*p == '<') ++angleDepth;
        else if (*p == '>' && --angleDepth == 0) break;
        ++p;
    }
    if (*p != '>') return nil; // no matching '>'
    
    NSString *signature = [[NSString alloc] initWithBytes:ivT+1 length:p-(ivT+1) encoding:NSUTF8StringEncoding];
    if (signature == nil) return nil;
    
    ivT = p + 1; // consume the signature, including '>'
    
    NSArray *types = [[self class] decodeTypes:signature flat:YES]; // block arguments are always flat, even in ivars
    NSString *returnType = [types count] > 0 ? types[0] : @"void";
    NSArray *argumentTypes = [types count] > 2 ? [types subarrayWithRange:NSMakeRange(2, [types count]-2)] : nil;
    NSString *arguments = [argumentTypes count] > 0 ? [argumentTypes componentsJoinedByString:@", "] : @"void";
    
    return [NSString stringWithFormat:@"%@ (^)(%@)", returnType, arguments];
}

- (RTBTypeDeclaration *)typeEncParseObjectRefInStruct:(BOOL)inStruct mayHaveClassName:(BOOL)mayHaveClassName spaceAfter:(BOOL)spaceAfter {
    NSString *typeS = nil;
    NSString *modifierS = @"";
    BOOL isUnnamedType = YES;
    const char *tmp;
    
    if (mayHaveClassName && (*ivT == '"') && (!inStruct || [self hasClassName])) {  // '@' followed by '"' implies the class name is supplied.
        ++ivT;  // skip the quote
        tmp = strchr(ivT, '"');  // go to the end of the quoted class name
        if (tmp != NULL) {       // (should never happen) no end quote -- default to type 'id' and hope this is parsed elsewhere
            isUnnamedType = NO;    // NO --> this is a named class (type)
            NSString *name = [[NSString alloc] initWithBytes:ivT length:tmp-ivT encoding:NSUTF8StringEncoding]; // get the name
            typeS = [[self class] objectTypeForQuotedName:name];
            if (spaceAfter && [typeS hasSuffix:@"*"] == NO) typeS = [typeS stringByAppendingString:@" "]; // id <NSCopying>
            ivT = tmp + 1;       // moved to the end of the name and the closing quote
        }
    }
    if (isUnnamedType) {
        
        BOOL isBlock = *ivT == '?';
        ivT += isBlock; // only increament ivT if the next character is actually being consumed
        
        if(isBlock && *ivT == '<') {
            NSString *blockType = [self parseBlockSignature];
            if(blockType) {
                typeS = (spaceAfter ? [blockType stringByAppendingString:@" "] : blockType);
                return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
            }
        }
        
        if(isBlock && _showCommentForBlocks) {
            typeS = (spaceAfter ? @"id /* block */ " : @"id /* block */");
        } else {
            typeS = (spaceAfter ? @"id " : @"id");
        }
    }
    
    return [RTBTypeDeclaration declarationWithType:typeS modifier:modifierS];
}

- (RTBTypeDeclaration *)flatCTypeDeclForEncType:(const char*)encType {
    ivT = encType;
    return [self flatCTypeDeclForEncType];
}

- (RTBTypeDeclaration *)ivarCTypeDeclForEncType:(const char*)encType {
    ivT = encType;
    return [self ivarCTypeDeclForEncType];
}

@end
