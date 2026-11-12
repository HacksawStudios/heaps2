package hxd.impl;

interface AsyncLoader {
	public function load( img : hxd.res.Image ) : Void;
	public function isSupported( t : hxd.res.Image ) : Bool;
}

#if (js && !macro)
class PakLoader implements AsyncLoader {

	var fs : hxd.fmt.pak.FileSystem;

	public function new() {
		fs = Std.downcast(hxd.res.Loader.currentInstance.fs, hxd.fmt.pak.FileSystem);
		if( fs == null ) throw "Loader should be pak filesystem";
	}

	public function isSupported( img : hxd.res.Image ) {
		return switch( img.getFormat() ) {
			case Ktx2ETC1S, Ktx2UASTC, Png, Jpg: true;
			default: false;
		}
	}

	public function load( img : hxd.res.Image ) {
		final data = fs.get(img.entry.path).getBytes();
		@:privateAccess img.asyncLoad(data);
	}

}
#end
