﻿package
{
	import flash.errors.IllegalOperationError;
	import flash.errors.IOError;
	import flash.events.DataEvent;
	import flash.events.ErrorEvent;
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.HTTPStatusEvent;
	import flash.events.IOErrorEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.net.URLRequestHeader;
	import flash.net.URLRequestMethod;
	import flash.net.URLVariables;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.Endian;
	import flash.utils.setTimeout;
	import flash.utils.clearInterval;
	import flash.utils.Timer;
	import flash.events.TimerEvent;
	import ExternalCall;


	/**
	 * Multipart URL Loader
	 *
	 * Original idea by Marston Development Studio - http://marstonstudio.com/?p=36
	 *
	 * License: MIT
	 *
	 * @author Eugene Zatepyakin
	 * @version 1.3
	 * @link http://blog.inspirit.ru/
	 *
	 *
	 * Heavily modified from the original version.  Removed multiple file support.
	 * Removed optional async data preparation (always async)
	 * After data is preparted the upload immediately starts.
	 * Updated to look and behave similar to the FileReference upload API
	 */
	public class  MultipartURLLoader extends EventDispatcher
	{
		public static var BLOCK_SIZE:uint = 64 * 1024;

		private var _loader:URLLoader;
		private var _request:URLRequest;
		private var _boundary:String;

		private var _fileName:String;
		private var _uploadDataFieldName:String;
		private var _fileData:ByteArray;
		private var _data:ByteArray;
		private var _httpStatus:Number;
		private var repeated:Boolean;
		private var asyncWriteTimeoutId:Number;
		private var timeoutTimer:Timer;
		private var progressTimer:Timer;

		private var _uploadSize:Number;
		public function get size():Number {
			return this._uploadSize;
		}

		private function debug(message:String):void {
			ExternalCall.Debug('SWFUpload.debug', message);
		}

		public function MultipartURLLoader(fileData:ByteArray, fileName:String) {
			_loader = new URLLoader();
			_fileData = fileData;
			_fileName = fileName;
			repeated = false;
			_uploadSize = 0;
		}

		public function upload(request:URLRequest, uploadDataFieldName:String = "Filedata"):void {
			trace('upload');
			_loader.addEventListener(IOErrorEvent.IO_ERROR, function(event:IOErrorEvent):void {
				trace('got ioError');
			});
			this._httpStatus = undefined;
			this._request = request;
			this._uploadDataFieldName = uploadDataFieldName;
			this.constructPostDataAsync();
		}

		/**
		 * Stop loader action
		 */
		public function cancel():void
		{
			try {
				clearInterval(this.asyncWriteTimeoutId);
				_loader.close();
			} catch ( e:Error ) { }

			this.destroy();
		}



		/**
		 * Dispose all class instance objects
		 */
		public function dispose(): void
		{
			try {
				this.cancel();
			} catch (ex:Error) {}
		}

		/**
		 * Generate random boundary
		 * @return	Random boundary
		 */
		public function getBoundary():String
		{
			if (_boundary == null) {
				_boundary = '';
				for (var i:int = 0; i < 0x20; i++ ) {
					_boundary += String.fromCharCode( int( 97 + Math.random() * 25 ) );
				}
			}
			return _boundary;
		}

		private function doSend():void
		{
			trace('doSend');
			var urlRequest:URLRequest = new URLRequest();
			urlRequest.url = this._request.url;
			//urlRequest.contentType = 'multipart/form-data; boundary=' + getBoundary();
			urlRequest.method = URLRequestMethod.POST;
			urlRequest.data = _data;

			urlRequest.requestHeaders = this._request.requestHeaders.concat();
			urlRequest.requestHeaders.push(new URLRequestHeader('Content-Type', 'multipart/form-data; boundary=' + getBoundary()));

			this._uploadSize = urlRequest.data.length;
			this.addListener();
			dispatchEvent(new Event(Event.OPEN, false, false));
			try {
				timeoutTimer.stop();
			} catch (ex:Error) {

			};
			try {
				progressTimer.stop();
			} catch (ex:Error) {

			};
			timeoutTimer = new Timer(300000);
			progressTimer = new Timer(300);
			var t:MultipartURLLoader = this;
			timeoutTimer.addEventListener(TimerEvent.TIMER, function(event:TimerEvent):void {
				dispatchEvent(event);
				t.destroy();
			});
			var tap:Number = 0;

			progressTimer.addEventListener(TimerEvent.TIMER, function(event:TimerEvent):void {
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, false, false, fakeProgress(), 100));
			});
			function fakeProgress ():Number {
				tap++;
				return 100 - 1 / (0.001*tap +0.01);
			}
			_loader.addEventListener(Event.COMPLETE, function(event:Event):void {
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, false, false, 100, 100));
				progressTimer.stop();
				timeoutTimer.stop();
			});
			trace('start to upload');
			try {
				timeoutTimer.start();
				progressTimer.start();
				_loader.load(urlRequest);
			} catch (ex:Error) {
				trace('IOError in dosend');
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, false, false, "Exception: " + ex.message));
				progressTimer.stop();
				timeoutTimer.stop();
				this.destroy();
			}

		}

		private function constructPostDataAsync():void
		{
			trace('constructPostDataAsync');
			clearInterval(this.asyncWriteTimeoutId);
			this._data = new ByteArray();
			this._data.endian = Endian.BIG_ENDIAN;
			this._data = constructVariablesPart(this._data);
			this._data = getFilePartHeader(this._data, this._fileName);

			this.asyncWriteTimeoutId = setTimeout(this.writeChunkLoop, 10, this._data, this._fileData, 0);

		}

		private function writeChunkLoop(dest:ByteArray, data:ByteArray, p:uint = 0):void
		{
			trace('writeChunkLoop');
			try {
				var len:uint = Math.min(BLOCK_SIZE, data.length - p);
				dest.writeBytes(data, p, len);

				if (len < BLOCK_SIZE || p + len >= data.length) {
					// Finished writing file bytearray
					dest = LINEBREAK(dest);
					this._data = closeFilePartsData(_data);
					this._data = closeDataObject(_data);
					this.doSend();
					return;
				}
				this.asyncWriteTimeoutId = setTimeout(this.writeChunkLoop, 10, dest, data, p + len);
			} catch (ex:Error) {
				trace('IOError in writeChunkLoop');
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR));
				this.destroy();
			}
		}

		private function closeDataObject(postData:ByteArray):ByteArray
		{
			postData = BOUNDARY(postData);
			postData = DOUBLEDASH(postData);
			return postData;
		}

		private function constructVariablesPart(postData:ByteArray):ByteArray
		{
			var i:uint;
			var bytes:String;

			if (this._request.data is URLVariables) {
				for (var name:String in this._request.data)
				{
					postData = BOUNDARY(postData);
					postData = LINEBREAK(postData);
					bytes = 'Content-Disposition: form-data; name="' + name + '"';
					for ( i = 0; i < bytes.length; i++ ) {
						postData.writeByte( bytes.charCodeAt(i) );
					}
					postData = LINEBREAK(postData);
					postData = LINEBREAK(postData);
					postData.writeUTFBytes(this._request.data[name]);
					postData = LINEBREAK(postData);
				}
			}

			return postData;
		}

		private function closeFilePartsData(postData:ByteArray):ByteArray
		{
			//var i:uint;
			//var bytes:String;
			//
			//postData = LINEBREAK(postData);
			//postData = BOUNDARY(postData);
			//postData = LINEBREAK(postData);
			//bytes = 'Content-Disposition: form-data; name="Upload"';
			//for ( i = 0; i < bytes.length; i++ ) {
				//postData.writeByte( bytes.charCodeAt(i) );
			//}
			//postData = LINEBREAK(postData);
			//postData = LINEBREAK(postData);
			//bytes = 'Submit Query';
			//for ( i = 0; i < bytes.length; i++ ) {
				//postData.writeByte( bytes.charCodeAt(i) );
			//}
			//postData = LINEBREAK(postData);

			return postData;
		}

		private function getFilePartHeader(postData:ByteArray, fileName:String):ByteArray
		{
			var i:uint;
			var bytes:String;

			postData = BOUNDARY(postData);
			postData = LINEBREAK(postData);
			bytes = 'Content-Disposition: form-data; name="' + this._uploadDataFieldName +  '"; filename="';
			for ( i = 0; i < bytes.length; i++ ) {
				postData.writeByte( bytes.charCodeAt(i) );
			}

			postData.writeUTFBytes(fileName);
			postData = QUOTATIONMARK(postData);

			postData = LINEBREAK(postData);
			bytes = 'Content-Type: application/octet-stream';
			for ( i = 0; i < bytes.length; i++ ) {
				postData.writeByte( bytes.charCodeAt(i) );
			}
			postData = LINEBREAK(postData);
			postData = LINEBREAK(postData);

			return postData;
		}

		private function onComplete( event: Event ): void
		{
			trace('onComplete');
			if (this._httpStatus === 200) {
				dispatchEvent(event);
				if (this._loader && this._loader.data && this._loader.data.length > 0) {
					dispatchEvent(new DataEvent(DataEvent.UPLOAD_COMPLETE_DATA, event.bubbles, event.cancelable, this._loader.data));
				}
			}
			this.destroy();
		}

		private function onIOError( event: IOErrorEvent ): void
		{
			trace('MultipartURLLoader dispatch IOError');
			dispatchEvent( event );
			this.destroy();
		}

		private function onSecurityError( event: SecurityErrorEvent ): void
		{
			trace('onSecurityError');
			dispatchEvent( event );
			this.destroy();
		}

		private function onHTTPStatus( event: HTTPStatusEvent ): void
		{
			if (event.status !== 200) {
				if (event.status === 400 && !repeated) {
					trace('dont dispatch http error', event.status);
					trace('try on more time');
					repeated = true;
					this.removeListener(); // onComplete wont be called
					try {
						timeoutTimer.stop();
					} catch (ex:Error) {

					}
					try {
						progressTimer.stop();
					} catch (ex:Error) {

					}
					constructPostDataAsync();
				} else {
					trace('dispatch http error', event.status);
					dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, event.bubbles, event.cancelable, event.status));
				}
			}
			this._httpStatus = event.status;
		}
		private function addListener(): void
		{
			trace('addListener');
			if (this._loader != null) {
				this._loader.addEventListener( Event.COMPLETE, this.onComplete, false, 0, false );
				this._loader.addEventListener( IOErrorEvent.IO_ERROR, this.onIOError, false, 0, false );
				this._loader.addEventListener( HTTPStatusEvent.HTTP_STATUS, this.onHTTPStatus, false, 0, false );
				this._loader.addEventListener( SecurityErrorEvent.SECURITY_ERROR, this.onSecurityError, false, 0, false );
			}
		}

		private function removeListener(): void
		{
			if (this._loader != null) {
				this._loader.removeEventListener( Event.COMPLETE, this.onComplete );
				this._loader.removeEventListener( IOErrorEvent.IO_ERROR, this.onIOError );
				this._loader.removeEventListener( HTTPStatusEvent.HTTP_STATUS, this.onHTTPStatus );
				this._loader.removeEventListener( SecurityErrorEvent.SECURITY_ERROR, this.onSecurityError );
			}
		}

		private function BOUNDARY(p:ByteArray):ByteArray
		{
			var l:int = getBoundary().length;
			p = DOUBLEDASH(p);
			for (var i:int = 0; i < l; i++ ) {
				p.writeByte( _boundary.charCodeAt( i ) );
			}
			return p;
		}

		private function LINEBREAK(p:ByteArray):ByteArray
		{
			p.writeShort(0x0d0a);
			return p;
		}

		private function QUOTATIONMARK(p:ByteArray):ByteArray
		{
			p.writeByte(0x22);
			return p;
		}

		private function DOUBLEDASH(p:ByteArray):ByteArray
		{
			p.writeShort(0x2d2d);
			return p;
		}

		private function destroy():void {
			try {
				this.removeListener();
			} catch (ex:Error) {}

			this._loader = null;
			this._request = null;
			this._boundary = null;

			this._fileName = null;
			this._uploadDataFieldName = null;
			if (this._fileData !== null) this._fileData.length = 0;
			this._fileData = null;
			if (this._data !== null) this._data.length = 0;
			this._data = null;
			this._httpStatus = undefined;

			try {
				clearInterval(this.asyncWriteTimeoutId);
			} catch (ex:Error) { }

			this.asyncWriteTimeoutId = undefined;
		}

	}
}