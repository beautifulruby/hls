# HLS

When I started working on the [Phlex on Rails video course](https://beautifulruby.com/phlex), I tried streaming mp4 files from an S3 compatible object store and quickly found out from users they were running into issues watching the video. I added to use [HLS](https://en.wikipedia.org/wiki/HTTP_Live_Streaming), but I quickly found out it's a bit of a pain setting that up on a private object store.

## Why?

Creating & serving HLS videos from private object stores is tricky.

### Sane encoding defaults

When you encode a video into HLS format, it cranks out different resolutions and bitrates that play on everything from mobile phones to TVs. You give it an input video and it writes out all the chunks into a directory.

### Generates pre-signed URLs in m3u8 playlists

The most annoying part about serving HLS videos from private object stores is generating pre-signed URLs for each chunk. This gem generates pre-signed URLs for each chunk in the m3u8 playlist, making it easy to serve HLS videos from private object stores.

### Rails integration

When a user requests a video, you probably want a controller that determines whether they have access to the video. If they do, the Rails integration will request a manifest file stored along side your video to generate the pre-signed URLs for each chunk.

Generators will also be included that pin an HLS polyfill for browsers that don't support HLS natively, like Chrome and Firefox.

## Support

Consider [buying a video course from Beautiful Ruby](https://beautifulruby.com) and learn a thing or two to keep the machine going that originally built this gem.

[![](https://immutable.terminalwire.com/NgTt6nzO1aEnExV8j6ODuKt2iZpY74ZF8ecpUSCp4A0tXA0ErpJIS4cdMX0tQQKOWwZSl65jWnpzpgCLJThhhWtZJGr42XKt7WIi.png)](https://beautifulruby.com/phlex/forms/overview)

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add hls
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install hls
```

## Usage

TODO: Write usage instructions here when the gem is finished

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/hls.
