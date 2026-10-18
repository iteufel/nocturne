    // Nocturne: recompute hit-test and drawing geometry after every scene resize.
    // This is inserted at the producer boundary in a generated copy of upstream source.
    _controlArea = _view.bounds;
    if (_iPad) {
        _controlArea.size.height = _view.bounds.size.height / 2.0;
        _controlArea.origin.y = _view.bounds.size.height - _controlArea.size.height;
    } else {
        _controlArea.origin.x = _controlArea.size.width * EDGE_WIDTH;
        _controlArea.size.width -= _controlArea.origin.x * 2;
    }
