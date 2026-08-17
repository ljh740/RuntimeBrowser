RuntimeBrowser
==============

This is a class browser for the Objective-C runtime on iOS and OS X. It gives you full access to all classes loaded in the runtime; allows you to dynamically load new modules and their classes; shows every method implemented on each class; and displays information in a header (.h) file format.

We have found this to be a useful development tool. Please note, however, that each user is responsible for their own usage.

The original version was released in April 2002 by [Ezra Epstein](https://github.com/eepstein). The project is maintained by Nicolas Seriot since August, 2008.

### iOS Version

  * browse by class tree, image or indexed list
  * search in classes names
  * headers retrieval through HTTP port 10000
  * instantiates most classes including allocation of non-shared instances
  * allows invocation of methods including inputting of parameters at runtime

You can browse the [iOS headers](https://github.com/nst/iOS-Runtime-Headers) as seen by RuntimeBrowser.

![RuntimeBrowser](art/screenshot_iphone.png "RuntimeBrowser iPhone")
![RuntimeBrowser](art/screenshot_iphone_2.png "RuntimeBrowser iPhone")
    
### OS X Version

Latest build: 2019-11-17 [http://seriot.ch/misc/RuntimeBrowser-0.997.zip](http://seriot.ch/misc/RuntimeBrowser-0.997.zip) 363 KB

  * browse by class tree, image, list or protocols
  * search in classes contents
  * syntax colorization
  * drag and drop frameworks and headers

![Screenshot](art/screenshot.png "RuntimeBrowser Mac OS X")

### Swift

Swift classes are visible in the Objective-C runtime with mangled names and without their Swift-only members. RuntimeBrowser demangles the names, reads the stored properties from the reflection metadata, recovers the members from the symbol tables of the images, and lists the Swift protocols the classes conform to.

The Swift structs, enums and protocols never enter the Objective-C runtime: they are read from the Swift metadata sections of the images and shown as Swift-like declarations, under a "Swift types" node in the Images view on OS X, and as `.swift` files in the web tree on iOS. The search covers them.

### runtime_cli

The command line front end of the model. `runtime_cli NSObject` prints a header, `runtime_cli --swift Foundation.Date` a Swift declaration, and `runtime_cli --sweep dir` writes the headers and declarations of everything it can load from /System/Library, which is how the model is tested against the whole runtime: sweep before and after a change, `diff -r` the two directories. See `runtime_cli.1`.
