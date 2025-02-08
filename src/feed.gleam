import birl

pub type Feed {
  Feed(name: String, url: String)
}

pub type Entry {
  Entry(title: String, url: String, published: birl.Time)
}
