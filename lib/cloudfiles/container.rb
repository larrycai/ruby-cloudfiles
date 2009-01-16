module CloudFiles
  class Container

    # Name of the container which corresponds to the instantiated container class
    attr_reader :containername

    # Size of the container (in bytes)
    attr_reader :size

    # Number of objects in the container
    attr_reader :count

    # True if container is public, false if container is private
    attr_reader :cdn_enabled

    # CDN container TTL (if container is public)
    attr_reader :cdn_ttl

    # CDN container URL (if container if public)
    attr_reader :cdn_url

    def initialize(cfclass,name) # :nodoc:
      @cfclass = cfclass
      @containername = name
      @storagehost = @cfclass.storagehost
      @storagepath = @cfclass.storagepath+"/"+@containername
      @cdnmgmthost = @cfclass.cdnmgmthost
      @cdnmgmtpath = @cfclass.cdnmgmtpath+"/"+@containername
      populate
    end

    # Retrieves data about the container and populates class variables.  It is automatically called
    # when the Container class is instantiated.  If you need to refresh the variables, such as 
    # size, count, cdn_enabled, cdn_ttl, and cdn_url, this method can be called again.
    def populate
      # Get the size and object count
      response = @cfclass.cfreq("HEAD",@storagehost,@storagepath+"/")
      raise NoSuchContainerException, "Container #{@containername} does not exist" unless (response.code == "204")
      @size = response["x-container-bytes-used"]
      @count = response["x-container-object-count"]

      # Get the CDN-related details
      response = @cfclass.cfreq("HEAD",@cdnmgmthost,@cdnmgmtpath)
      if (response.code == "204")
        @cdn_enabled = true
        @cdn_ttl = response["x-ttl"]
        @cdn_url = response["x-cdn-uri"]
      else
        @cdn_enabled = false
        @cdn_ttl = false
        @cdn_url = false
      end
    end

    # Returns an Object object that can be manipulated.  Refer to the Egg class for available
    # methods.  Throws NoSuchObjectException if the object does not exist.
    def object(objectname)
      CloudFiles::StorageObject.new(@cfclass,@containername,objectname)
    end

    # Gathers a list of all available objects in the current container.  If no arguments
    # are passed, all available objects will be retrieved in an array:
    #   cntnr = cf.container("My Container")
    #   cntnr.objects                     #=> [ "dog", "cat", "donkey"]
    # Pass a limit argument to limit the list to a number of objects:
    #   cntnr.objects(1)                  #=> [ "dog" ]
    # Pass an offset with or without a limit to start the list at a certain object:
    #   cntnr.objects(1,2)                #=> [ "donkey" ]
    # Pass a prefix to search for objects that start with a certain string:
    #   cntnr.objects(nil,nil,"do")       #=> [ "dog", "donkey" ]
    # All arguments to this method are optional.
    # 
    # Returns an empty array if no object exist in the container.  Throws an InvalidResponseException
    # if the request fails.
    def objects(limit = nil, offset = nil, prefix = nil)
      paramarr = []
      paramarr << ["limit=#{limit}"] if (!limit.nil?)
      paramarr << ["offset=#{offset}"] if (!offset.nil?)
      paramarr << ["prefix=#{prefix}"] if (!prefix.nil?)
      paramstr = (paramarr.size > 0)? paramarr.join("&") : "" ;
      response = @cfclass.cfreq("GET",@storagehost,"#{@storagepath}?#{paramstr}")
      return [] if (response.code == "204")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "200")
      return response.body.to_a.map { |x| x.chomp }
    end

    # Retrieves a list of all objects in the current container along with their size, md5sum, and contenttype.
    # If no objects exist, an empty hash is returned.  Throws an InvalidResponseException if the request fails.
    # 
    # Returns a hash in the same format as the containers_detail from the CloudFiles class.
    def objects_detail(limit = nil, offset = nil, prefix = nil)
      paramarr = []
      paramarr << ["format=xml"]
      paramarr << ["limit=#{limit}"] if (!limit.nil?)
      paramarr << ["offset=#{offset}"] if (!offset.nil?)
      paramarr << ["prefix=#{prefix}"] if (!prefix.nil?)
      paramstr = (paramarr.size > 0)? paramarr.join("&") : "" ;
      response = @cfclass.cfreq("GET",@storagehost,"#{@storagepath}?#{paramstr}")
      return [] if (response.code == "204")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "200")
      doc = REXML::Document.new(response.body)
      detailhash = {}
      doc.elements.each("container/object") { |o|
        detailhash[o.elements["name"].text] = { :size => o.elements["size"].text, :md5sum => o.elements["hash"].text, :contenttype => o.elements["type"].text }
      }
      doc = nil
      return detailhash
    end

    # Returns true if the container is public and CDN-enabled.  Returns false otherwise.
    def public?
      return @cdn_enabled
    end

    # Returns true if a container is empty and returns false otherwise.
    def empty?
      return (@count.to_i == 0)? true : false
    end

    # Returns true if object exists and returns false otherwise.
    def object_exists?(objectname)
      response = @cfclass.cfreq("HEAD",@storagehost,"#{@storagepath}/#{objectname}")
      return (response.code == "204")? true : false
    end

    # Creates an object in the current container and populates it with data.  The data argument is required
    # and it can be a string or an IO stream.  If a stream is used, the data is read in chunks without 
    # placing the entire file into memory.  While the headers are optional, it's recommended that you provide
    # a content type so that it is accurate when you retrieve the data.  Headers can be passed as a hash.
    # 
    # A successful retrieval will return an Egg object that can be manipulated further.  Throws InvalidResponseException
    # if the content-length header does not match (should not occur under normal circumstances) or if the request failed.
    # Throws MisMatchedChecksumException if the uploaded data does not match the MD5 hash that is calculated at upload time.
    def object_create(objectname,data,headers = nil)
      raise SyntaxException, "No data was provided for object '#{objectname}'" if (data.nil?)
      headers = { "Content-Type" => "application/octet-stream" } if (headers.nil?)
      headers["ETag"] = Digest::MD5.hexdigest(data).to_s
      response = @cfclass.cfreq("PUT",@storagehost,"#{@storagepath}/#{objectname}",headers,data)
      raise InvalidResponseException, "Invalid content-length header sent" if (response.code == "412")
      raise MisMatchedChecksumException, "Mismatched md5sum" if (response.code == "422")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "201")
      populate
      CloudFiles::StorageObject.new(@cfclass,@containername,objectname)
    end

    # Removes an object from a container.  True is returned if the removal is successful.  Throws NoSuchObjectException
    # if the object doesn't exist.  Throws InvalidResponseException if the request fails.
    def object_delete(objectname)
      response = @cfclass.cfreq("DELETE",@storagehost,"#{@storagepath}/#{objectname}")
      raise NoSuchObjectException, "Object #{objectname} does not exist" if (response.code == "404")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "204")
      populate
      true
    end

    # Makes a container publicly available via the Cloud Files CDN and returns true upon success.  Throws NoSuchContainerException
    # if the container doesn't exist or if the request fails.
    def make_public
      headers = { "X-CDN-Enabled" => "True" }
      response = @cfclass.cfreq("PUT",@cdnmgmthost,@cdnmgmtpath,headers)
      raise NoSuchContainerException, "Container #{@containername} does not exist" unless (response.code == "201" || response.code == "202")
      populate
      true
    end

    # Makes a container private and returns true upon success.  Throws NoSuchContainerException
    # if the container doesn't exist or if the request fails.
    def make_private
      headers = { "X-CDN-Enabled" => "False" }
      response = @cfclass.cfreq("PUT",@cdnmgmthost,@cdnmgmtpath,headers)
      raise NoSuchContainerException, "Container #{@containername} does not exist" unless (response.code == "201" || response.code == "202")
      populate
      true
    end

    # Sets the CDN TTL for a public container and returns true upon success.  Throws NoSuchContainerException
    # if the container isn't public.
    def set_ttl(ttlvalue)
      return false if (ttlvalue.to_i == 0)
      headers = { "X-TTL" => ttlvalue }
      response = @cfclass.cfreq("PUT",@cdnmgmthost,@cdnmgmtpath,headers)
      raise NoSuchContainerException, "Container #{@containername} does not exist" unless (response.code == "201" || response.code == "202")
      populate
      true
    end

  end

end