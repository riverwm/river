const View = @import("view.zig").View;

/// A specialized doubly-linked stack that allows for filtered iteration
/// over the nodes
pub const ViewStack = struct {
    const Self = @This();

    pub const Node = struct {
        /// Previous/next nodes in the stack
        prev: ?*Node,
        next: ?*Node,

        /// The view stored in this node
        view: View,
    };

    /// Top/bottom nodes in the stack
    first: ?*Node,
    last: ?*Node,

    /// Total number of views
    len: u32,

    /// Initialize an undefined stack
    pub fn init(self: *Self) void {
        self.first = null;
        self.last = null;
        self.len = 0;
    }

    /// Add a node to the top of the stack.
    pub fn push(self: *Self, new_node: *Node) void {
        // Set the prev/next pointers of the new node
        new_node.prev = null;
        new_node.next = self.first;

        if (self.first) |first| {
            // If the list is not empty, set the prev pointer of the current
            // first node to the new node.
            first.prev = new_node;
        } else {
            // If the list is empty set the last pointer to the new node.
            self.last = new_node;
        }

        // Set the first pointer to the new node and increment length
        self.first = new_node;
        self.len += 1;
    }

    /// Remove a node from the view stack. This removes it from the stack of
    /// all views as well as the stack of visible ones.
    pub fn remove(self: *Self, target_node: *Node) void {
        // Set the previous node/list head to the next pointer
        if (target_node.prev) |prev_node| {
            prev_node.next = target_node.next;
        } else {
            self.first = target_node.next;
        }

        // Set the next node/list tail to the previous pointer
        if (target_node.next) |next_node| {
            next_node.prev = target_node.prev;
        } else {
            self.last = target_node.prev;
        }

        self.len -= 1;
    }

    const Iterator = struct {
        it: ?*Node,
        tags: u32,
        reverse: bool,
        pending: bool,

        /// Returns the next node in iteration order, or null if done.
        /// This function is horribly ugly, but it's well tested below.
        pub fn next(self: *Iterator) ?*View {
            while (self.it) |node| : (self.it = if (self.reverse) node.prev else node.next) {
                if (node.view.mapped and if (self.pending)
                    if (node.view.pending_tags) |pending_tags|
                        self.tags & pending_tags != 0
                    else
                        self.tags & node.view.current_tags != 0
                else
                    self.tags & node.view.current_tags != 0) {
                    const ret = &node.view;
                    self.it = if (self.reverse) node.prev else node.next;
                    return ret;
                }
            }
            return null;
        }
    };

    /// Returns an iterator starting at the passed node and filtered by
    /// checking the passed tags against the current tags of each view.
    /// Unmapped views are skipped.
    pub fn iterator(start: ?*Node, tags: u32) Iterator {
        return Iterator{
            .it = start,
            .tags = tags,
            .reverse = false,
            .pending = false,
        };
    }

    /// Returns a reverse iterator starting at the passed node and filtered by
    /// checking the passed tags against the current tags of each view.
    /// Unmapped views are skipped.
    pub fn reverseIterator(start: ?*Node, tags: u32) Iterator {
        return Iterator{
            .it = start,
            .tags = tags,
            .reverse = true,
            .pending = false,
        };
    }

    /// Returns an iterator starting at the passed node and filtered by
    /// checking the passed tags against the pending tags of each view.
    /// If a view has no pending tags, the current tags are used. Unmapped
    /// views are skipped.
    pub fn pendingIterator(start: ?*Node, tags: u32) Iterator {
        return Iterator{
            .it = start,
            .tags = tags,
            .reverse = false,
            .pending = true,
        };
    }
};

const testing = @import("std").testing;

test "push/remove" {
    const allocator = testing.allocator;

    var views: ViewStack = undefined;
    views.init();

    var one = try allocator.create(ViewStack.Node);
    defer allocator.destroy(one);
    var two = try allocator.create(ViewStack.Node);
    defer allocator.destroy(two);
    var three = try allocator.create(ViewStack.Node);
    defer allocator.destroy(three);
    var four = try allocator.create(ViewStack.Node);
    defer allocator.destroy(four);
    var five = try allocator.create(ViewStack.Node);
    defer allocator.destroy(five);

    testing.expect(views.len == 0);
    views.push(three); // {3}
    views.push(one); // {1, 3}
    views.push(four); // {4, 1, 3}
    views.push(five); // {5, 4, 1, 3}
    views.push(two); // {2, 5, 4, 1, 3}
    testing.expect(views.len == 5);

    // Simple insertion
    {
        var it = views.first;
        testing.expect(it == two);
        it = it.?.next;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;
        testing.expect(it == three);
        it = it.?.next;

        testing.expect(it == null);
        testing.expect(views.len == 5);

        testing.expect(views.first == two);
        testing.expect(views.last == three);
    }

    // Removal of first
    views.remove(two);
    {
        var it = views.first;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;
        testing.expect(it == three);
        it = it.?.next;

        testing.expect(it == null);
        testing.expect(views.len == 4);

        testing.expect(views.first == five);
        testing.expect(views.last == three);
    }

    // Removal of last
    views.remove(three);
    {
        var it = views.first;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;

        testing.expect(it == null);
        testing.expect(views.len == 3);

        testing.expect(views.first == five);
        testing.expect(views.last == one);
    }

    // Remove from middle
    views.remove(four);
    {
        var it = views.first;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;

        testing.expect(it == null);
        testing.expect(views.len == 2);

        testing.expect(views.first == five);
        testing.expect(views.last == one);
    }

    // Reinsertion
    views.push(two);
    views.push(three);
    views.push(four);
    {
        var it = views.first;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == three);
        it = it.?.next;
        testing.expect(it == two);
        it = it.?.next;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;

        testing.expect(it == null);
        testing.expect(views.len == 5);

        testing.expect(views.first == four);
        testing.expect(views.last == one);
    }

    // Clear
    views.remove(four);
    views.remove(two);
    views.remove(three);
    views.remove(one);
    views.remove(five);

    testing.expect(views.first == null);
    testing.expect(views.last == null);
    testing.expect(views.len == 0);
}

test "iteration" {
    const allocator = testing.allocator;

    var views: ViewStack = undefined;
    views.init();

    var one_a_pb = try allocator.create(ViewStack.Node);
    defer allocator.destroy(one_a_pb);
    one_a_pb.view.mapped = true;
    one_a_pb.view.current_tags = 1 << 0;
    one_a_pb.view.pending_tags = 1 << 1;

    var two_a = try allocator.create(ViewStack.Node);
    defer allocator.destroy(two_a);
    two_a.view.mapped = true;
    two_a.view.current_tags = 1 << 0;

    var three_b_pa = try allocator.create(ViewStack.Node);
    defer allocator.destroy(three_b_pa);
    three_b_pa.view.mapped = true;
    three_b_pa.view.current_tags = 1 << 1;
    three_b_pa.view.pending_tags = 1 << 0;

    var four_b = try allocator.create(ViewStack.Node);
    defer allocator.destroy(four_b);
    four_b.view.mapped = true;
    four_b.view.current_tags = 1 << 1;

    var five_b = try allocator.create(ViewStack.Node);
    defer allocator.destroy(five_b);
    five_b.view.mapped = true;
    five_b.view.current_tags = 1 << 1;

    views.push(three_b_pa); // {3}
    views.push(one_a_pb); // {1, 3}
    views.push(four_b); // {4, 1, 3}
    views.push(five_b); // {5, 4, 1, 3}
    views.push(two_a); // {2, 5, 4, 1, 3}

    // Iteration over all tags
    {
        var it = ViewStack.iterator(views.first, 0xFFFFFFFF);
        testing.expect(it.next() == &two_a.view);
        testing.expect(it.next() == &five_b.view);
        testing.expect(it.next() == &four_b.view);
        testing.expect(it.next() == &one_a_pb.view);
        testing.expect(it.next() == &three_b_pa.view);
        testing.expect(it.next() == null);
    }

    // Iteration over 'a' tags
    {
        var it = ViewStack.iterator(views.first, 1 << 0);
        testing.expect(it.next() == &two_a.view);
        testing.expect(it.next() == &one_a_pb.view);
        testing.expect(it.next() == null);
    }

    // Iteration over 'b' tags
    {
        var it = ViewStack.iterator(views.first, 1 << 1);
        testing.expect(it.next() == &five_b.view);
        testing.expect(it.next() == &four_b.view);
        testing.expect(it.next() == &three_b_pa.view);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over all tags
    {
        var it = ViewStack.reverseIterator(views.last, 0xFFFFFFFF);
        testing.expect(it.next() == &three_b_pa.view);
        testing.expect(it.next() == &one_a_pb.view);
        testing.expect(it.next() == &four_b.view);
        testing.expect(it.next() == &five_b.view);
        testing.expect(it.next() == &two_a.view);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over 'a' tags
    {
        var it = ViewStack.reverseIterator(views.last, 1 << 0);
        testing.expect(it.next() == &one_a_pb.view);
        testing.expect(it.next() == &two_a.view);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over 'b' tags
    {
        var it = ViewStack.reverseIterator(views.last, 1 << 1);
        testing.expect(it.next() == &three_b_pa.view);
        testing.expect(it.next() == &four_b.view);
        testing.expect(it.next() == &five_b.view);
        testing.expect(it.next() == null);
    }

    // Iteration over (pending) 'a' tags
    {
        var it = ViewStack.pendingIterator(views.first, 1 << 0);
        testing.expect(it.next() == &two_a.view);
        testing.expect(it.next() == &three_b_pa.view);
        testing.expect(it.next() == null);
    }

    // Iteration over (pending) 'b' tags
    {
        var it = ViewStack.pendingIterator(views.first, 1 << 1);
        testing.expect(it.next() == &five_b.view);
        testing.expect(it.next() == &four_b.view);
        testing.expect(it.next() == &one_a_pb.view);
        testing.expect(it.next() == null);
    }
}
