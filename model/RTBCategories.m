//
//  RTBCategories.m
//  RuntimeBrowser
//
//  See RTBCategories.h
//

#import "RTBCategories.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

/*
 The runtime structures we read, see objc-runtime-new.h in objc4. Only the leading fields are used.

 struct category_t {
     const char *name;
     Class cls;
     struct method_list_t *instanceMethods;
     struct method_list_t *classMethods;
     ...
 };

 struct method_list_t {
     uint32_t entsizeAndFlags; // the low bits and the high bits are flags, eg. 0x80000000 for the small (relative) methods
     uint32_t count;
     ... count entries of entsize bytes
 };

 A Method is a pointer to an entry. The runtime tags the pointers to small methods with their low bit.
 */

typedef struct {
    const char *name;
    void *cls;
    void *instanceMethods;
    void *classMethods;
} rtb_category_t;

typedef struct {
    uintptr_t start;
    uintptr_t end;
    const char *categoryName; // in the image, which stays loaded
} RTBCategoryMethodList;

typedef struct {
    RTBCategoryMethodList *lists; // sorted by start
    size_t count;
    size_t capacity;
    uint32_t imageCount; // _dyld_image_count() when built, to rebuild after a bundle is loaded
} RTBCategoriesIndex;

static int rtb_compareMethodLists(const void *a, const void *b) {
    uintptr_t x = ((const RTBCategoryMethodList *)a)->start;
    uintptr_t y = ((const RTBCategoryMethodList *)b)->start;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static void rtb_indexMethodList(RTBCategoriesIndex *index, const void *list, const char *categoryName) {
    if(list == NULL) return;

    const uint32_t *header = (const uint32_t *)list;
    uint32_t entsize = header[0] & 0x0000FFFC; // 12 for small methods, 24 for the others
    uint32_t count = header[1];
    if((entsize != 12 && entsize != 24) || count == 0 || count > 100000) return; // does not look like a method list

    if(index->count == index->capacity) {
        index->capacity = index->capacity ? index->capacity * 2 : 1024;
        index->lists = realloc(index->lists, index->capacity * sizeof(RTBCategoryMethodList));
    }

    RTBCategoryMethodList *l = &index->lists[index->count++];
    l->start = (uintptr_t)list;
    l->end = (uintptr_t)list + 8 + (uintptr_t)count * entsize;
    l->categoryName = categoryName;
}

static void rtb_indexImage(RTBCategoriesIndex *index, const struct mach_header *header) {

    if(header->flags & MH_DYLIB_IN_CACHE) return; // the shared cache builder merges the categories, see RTBCategories.h

#if __LP64__
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
#else
    const struct mach_header *mh = header;
#endif

    static const char *segments[] = { "__DATA", "__DATA_CONST", "__DATA_DIRTY" };
    static const char *sections[] = { "__objc_catlist", "__objc_catlist2" }; // catlist2 for the categories of Swift class stubs

    for(size_t s = 0; s < sizeof(segments) / sizeof(segments[0]); s++) {
        for(size_t t = 0; t < sizeof(sections) / sizeof(sections[0]); t++) {
            unsigned long size = 0;
            const uint8_t *data = getsectiondata(mh, segments[s], sections[t], &size);
            if(data == NULL) continue;

            const rtb_category_t **categories = (const rtb_category_t **)data;
            for(unsigned long i = 0; i < size / sizeof(void *); i++) {
                const rtb_category_t *category = categories[i];
                if(category == NULL || category->name == NULL) continue;
                rtb_indexMethodList(index, category->instanceMethods, category->name);
                rtb_indexMethodList(index, category->classMethods, category->name);
            }
        }
    }
}

static RTBCategoriesIndex *rtb_categoriesIndex(void) {

    static RTBCategoriesIndex *index = NULL;
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });

    [lock lock];

    uint32_t imageCount = _dyld_image_count();

    if(index == NULL || index->imageCount != imageCount) {
        RTBCategoriesIndex *newIndex = calloc(1, sizeof(RTBCategoriesIndex));
        newIndex->imageCount = imageCount;
        for(uint32_t i = 0; i < imageCount; i++) {
            const struct mach_header *header = _dyld_get_image_header(i);
            if(header) rtb_indexImage(newIndex, header);
        }
        qsort(newIndex->lists, newIndex->count, sizeof(RTBCategoryMethodList), rtb_compareMethodLists);

        // the previous index is leaked on purpose, another thread may still be reading it
        index = newIndex;
    }

    RTBCategoriesIndex *result = index;

    [lock unlock];

    return result;
}

@implementation RTBCategories

+ (NSString *)categoryNameForMethod:(Method)method {

    if(method == NULL) return nil;

    RTBCategoriesIndex *index = rtb_categoriesIndex();
    if(index->count == 0) return nil;

    uintptr_t p = (uintptr_t)method & ~(uintptr_t)1; // small methods are tagged

    // the last list starting at or before p
    size_t low = 0, high = index->count;
    while(low < high) {
        size_t mid = (low + high) / 2;
        if(index->lists[mid].start <= p) low = mid + 1;
        else high = mid;
    }
    if(low == 0) return nil;

    const RTBCategoryMethodList *list = &index->lists[low - 1];
    if(p < list->start || p >= list->end) return nil;

    return [NSString stringWithCString:list->categoryName encoding:NSUTF8StringEncoding];
}

@end
